//
//  HealthKitManager.swift
//  Exporter
//
//  HealthKit 授权与读取：增量（HKAnchoredObjectQuery）与日期段（HKSampleQuery）。
//  查询/归一化为 nonisolated，跑在后台线程，避免阻塞主线程。
//  覆盖全量类型目录：quantity / category 通用路径 + 各特殊样本类型按 kind 分派转换。
//

import Foundation
#if canImport(HealthKit)
import HealthKit

// MARK: - HealthMetric ↔ HealthKit 映射（仅在支持 HealthKit 的平台编译）

extension HealthMetric {
    /// HK 标识符后缀：rawValue 首字母大写；官方大小写/历史更名特例单列。
    private nonisolated var hkIdentifierSuffix: String {
        switch rawValue {
        case "vo2Max":     return "VO2Max"
        case "uvExposure": return "UVExposure"
        // iOS 14 由 audioExposureEvent 更名而来，原始标识符字符串保留旧名。
        case "environmentalAudioExposureEvent": return "AudioExposureEvent"
        default:           return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// 对应的 HealthKit 样本类型；目录与 SDK 不一致时为 nil（单测全量校验非 nil）。
    nonisolated var sampleType: HKSampleType? {
        switch kind {
        case .quantity:
            return HKObjectType.quantityType(
                forIdentifier: HKQuantityTypeIdentifier(rawValue: "HKQuantityTypeIdentifier" + hkIdentifierSuffix))
        case .category:
            return HKObjectType.categoryType(
                forIdentifier: HKCategoryTypeIdentifier(rawValue: "HKCategoryTypeIdentifier" + hkIdentifierSuffix))
        case .workout:            return HKObjectType.workoutType()
        case .stateOfMind:        return HKObjectType.stateOfMindType()
        case .electrocardiogram:  return HKObjectType.electrocardiogramType()
        case .audiogram:          return HKObjectType.audiogramSampleType()
        case .scoredAssessment:
            return HKScoredAssessmentType(
                HKScoredAssessmentTypeIdentifier(rawValue: "HKScoredAssessmentTypeIdentifier" + rawValue))
        case .visionPrescription: return HKObjectType.visionPrescriptionType()
        case .medicationDose:     return HKObjectType.medicationDoseEventType()
        }
    }

    /// 数值型样本读取所用单位；分类型/特殊类型为 nil。
    nonisolated var hkUnit: HKUnit? {
        unitString.flatMap { HealthMetric.unitTable[$0] }
    }

    /// 目录中出现的全部单位字符串 → HKUnit。显式构造而非 HKUnit(from:)，零解析风险。
    nonisolated static let unitTable: [String: HKUnit] = [
        "count":            .count(),
        "kcal":             .kilocalorie(),
        "min":              .minute(),
        "m":                .meter(),
        "cm":               .meterUnit(with: .centi),
        "m/s":              HKUnit.meter().unitDivided(by: .second()),
        "count/min":        HKUnit.count().unitDivided(by: .minute()),
        "W":                .watt(),
        "ms":               .secondUnit(with: .milli),
        "kg":               .gramUnit(with: .kilo),
        "g":                .gram(),
        "%":                .percent(),
        "degC":             .degreeCelsius(),
        "S":                .siemen(),
        "L":                .liter(),
        "L/min":            HKUnit.liter().unitDivided(by: .minute()),
        "mL":               .literUnit(with: .milli),
        "mmHg":             .millimeterOfMercury(),
        "IU":               .internationalUnit(),
        "mg/dL":            HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)),
        "dBASPL":           .decibelAWeightedSoundPressureLevel(),
        "appleEffortScore": .appleEffortScore(),
        "kcal/(kg*hr)":     HKUnit.kilocalorie()
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour())),
        "ml/(kg*min)":      HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())),
    ]
}

// MARK: - Manager

@MainActor
@Observable
final class HealthKitManager {
    enum HealthError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: return "此设备不支持 HealthKit。"
            }
        }
    }

    // 二者均为 Sendable / 线程安全，标 nonisolated 以便后台线程的查询方法访问。
    private nonisolated let healthStore = HKHealthStore()
    private nonisolated let anchorStore = AnchorStore()

    /// 同时进行的 HealthKit 查询上限（全量近 200 类型，避免无界并发）。
    private nonisolated static let maxConcurrentQueries = 12

    /// 是否已发起过授权请求（HealthKit 不暴露读权限的具体状态，仅记录是否请求过）。
    private(set) var hasRequestedAuthorization = false

    nonisolated var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// 个人特征类型（出生日期/性别/血型/肤型/轮椅/活动模式），随样本类型一并请求读权限。
    private nonisolated static var characteristicTypes: [HKObjectType] {
        [HKCharacteristicTypeIdentifier.dateOfBirth, .biologicalSex, .bloodType,
         .fitzpatrickSkinType, .wheelchairUse, .activityMoveMode]
            .compactMap { HKObjectType.characteristicType(forIdentifier: $0) }
    }

    // MARK: 授权

    /// 该指标是否走逐对象授权（不能进 requestAuthorization / getRequestStatus 的读集合，
    /// 否则 HealthKit 抛 NSException）。用药记录的授权挂在 userAnnotatedMedicationType 上，
    /// 其 dose event 类型对标准授权 API 完全禁用，故按 kind 显式排除。
    /// internal（非 private）：供守门单测断言逐对象类型永不进标准读集合。
    nonisolated static func isPerObjectAuthorized(_ metric: HealthMetric) -> Bool {
        metric.kind == .medicationDose
            || metric.sampleType?.requiresPerObjectAuthorization() == true
    }

    /// 标准授权读集合：排除逐对象授权类型（视力处方/用药记录）。internal（非 private）：供守门单测。
    nonisolated static func standardReadTypes(for metrics: [HealthMetric]) -> Set<HKObjectType> {
        let sampleTypes = metrics.filter { !isPerObjectAuthorized($0) }
            .compactMap { $0.sampleType as HKObjectType? }
        return Set(sampleTypes + characteristicTypes)
    }

    /// 逐对象授权请求的目标类型（各自弹独立系统面板）。
    /// 用药记录映射到 userAnnotatedMedicationType（按药物授权，dose event 随之可读）。
    private nonisolated static func perObjectAuthTargets(for metrics: [HealthMetric]) -> [HKObjectType] {
        metrics.filter(isPerObjectAuthorized).compactMap { metric in
            metric.kind == .medicationDose
                ? HKObjectType.userAnnotatedMedicationType()
                : metric.sampleType
        }
    }

    func requestAuthorization(for metrics: [HealthMetric]) async throws {
        guard isHealthDataAvailable else { throw HealthError.unavailable }
        try await healthStore.requestAuthorization(toShare: [], read: Self.standardReadTypes(for: metrics))
        // 逐对象类型逐个请求；用户拒绝/取消不影响其余授权。
        for type in Self.perObjectAuthTargets(for: metrics) {
            _ = try? await healthStore.requestPerObjectReadAuthorization(for: type, predicate: nil)
        }
        hasRequestedAuthorization = true
    }

    /// 系统是否还会为这些类型弹出授权面板。`.unnecessary` 表示已决，无法再弹。
    nonisolated func authorizationRequestStatus(for metrics: [HealthMetric]) async -> HKAuthorizationRequestStatus {
        guard isHealthDataAvailable else { return .unknown }
        let readTypes = Self.standardReadTypes(for: metrics)
        return await withCheckedContinuation { continuation in
            healthStore.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, _ in
                continuation.resume(returning: status)
            }
        }
    }

    /// 授权是否已决（系统不会再弹面板）。已决后只能引导用户去系统设置 / 健康 App 修改。
    nonisolated func isAuthorizationDetermined(for metrics: [HealthMetric]) async -> Bool {
        await authorizationRequestStatus(for: metrics) == .unnecessary
    }

    /// 轻量探测：返回该指标最近一条样本的时间（读到=有数据/已授权；nil=无数据或未授权）。
    nonisolated func probeLatest(_ metric: HealthMetric) async -> Date? {
        guard let type = metric.sampleType else { return nil }
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        let samples = try? await runSampleQuery(type, predicate: nil, limit: 1, sort: sort)
        return samples?.first?.endDate
    }

    // MARK: 个人特征

    /// 读取个人特征（非样本）。逐项容错：未授权 / 未设置的项为 nil。
    nonisolated func readProfile() -> ExportProfile {
        var profile = ExportProfile()
        if let components = try? healthStore.dateOfBirthComponents(),
           let year = components.year, let month = components.month, let day = components.day {
            profile.dateOfBirth = String(format: "%04d-%02d-%02d", year, month, day)
        }
        if let sex = try? healthStore.biologicalSex().biologicalSex {
            profile.biologicalSex = Self.biologicalSexName(sex)
        }
        if let blood = try? healthStore.bloodType().bloodType {
            profile.bloodType = Self.bloodTypeName(blood)
        }
        if let skin = try? healthStore.fitzpatrickSkinType().skinType {
            profile.fitzpatrickSkinType = Self.skinTypeName(skin)
        }
        if let wheelchair = try? healthStore.wheelchairUse().wheelchairUse {
            profile.wheelchairUse = Self.wheelchairUseName(wheelchair)
        }
        if let moveMode = try? healthStore.activityMoveMode().activityMoveMode {
            profile.activityMoveMode = Self.activityMoveModeName(moveMode)
        }
        return profile
    }

    // MARK: 读取入口

    /// 读取结果。增量模式携带待提交的 anchor（归档为 Data，Sendable），
    /// 由调用方在用户确认后 `commit(_:)`，避免估算/取消时误推进 anchor。
    nonisolated struct FetchOutcome: Sendable {
        let samples: [HealthSample]
        let pendingAnchors: [PendingAnchor]
        let isIncremental: Bool
        /// 因授权未决/被拒而跳过的指标（授权面板可能隐藏部分类型，无法授予）。
        let skippedMetrics: [HealthMetric]

        struct PendingAnchor: Sendable {
            let metric: HealthMetric
            let anchorData: Data
        }
    }

    /// 按所选指标与模式读取并归一化样本（窗口式并发，上限 maxConcurrentQueries）。
    /// - Parameter maxLookback: 可选回溯上限（活口）；设置后只读取 now-maxLookback 之后的数据。
    nonisolated func fetch(metrics: [HealthMetric],
                           mode: SyncMode,
                           start: Date?,
                           end: Date?,
                           maxLookback: TimeInterval? = nil) async throws -> FetchOutcome {
        guard isHealthDataAvailable else { throw HealthError.unavailable }
        typealias Part = (samples: [HealthSample], anchor: FetchOutcome.PendingAnchor?, skipped: HealthMetric?)
        return try await withThrowingTaskGroup(of: Part.self) { group in
            func submit(_ metric: HealthMetric, to group: inout ThrowingTaskGroup<Part, Error>) {
                group.addTask {
                    do {
                        switch mode {
                        case .incremental:
                            let (samples, anchorData) = try await self.fetchIncremental(metric, maxLookback: maxLookback)
                            let pending = anchorData.map { FetchOutcome.PendingAnchor(metric: metric, anchorData: $0) }
                            return (samples, pending, nil)
                        case .range:
                            let samples = try await self.fetchRange(metric, start: start, end: end, maxLookback: maxLookback)
                            return (samples, nil, nil)
                        }
                    } catch where Self.shouldSkip(error, metric: metric) {
                        // 授权未决/被拒（授权面板可能隐藏部分类型）或逐对象授权类型未授权：
                        // 跳过该指标并上报，不让单个指标炸掉整体导出。
                        return ([], nil, metric)
                    }
                }
            }

            var nextIndex = 0
            while nextIndex < min(Self.maxConcurrentQueries, metrics.count) {
                submit(metrics[nextIndex], to: &group)
                nextIndex += 1
            }

            var all: [HealthSample] = []
            var anchors: [FetchOutcome.PendingAnchor] = []
            var skipped: [HealthMetric] = []
            while let part = try await group.next() {
                all += part.samples
                if let anchor = part.anchor { anchors.append(anchor) }
                if let metric = part.skipped { skipped.append(metric) }
                if nextIndex < metrics.count {
                    submit(metrics[nextIndex], to: &group)
                    nextIndex += 1
                }
            }
            return FetchOutcome(samples: all.sorted { $0.start < $1.start },
                                pendingAnchors: anchors,
                                isIncremental: mode == .incremental,
                                skippedMetrics: skipped)
        }
    }

    /// 单指标查询失败是否应跳过（而非让整体导出失败）：
    /// 授权未决/被拒的指标（部分类型不出现在授权面板，用户无法授予），
    /// 以及逐对象授权类型（视力处方/用药）的任何错误。
    private nonisolated static func shouldSkip(_ error: Error, metric: HealthMetric) -> Bool {
        if isPerObjectAuthorized(metric) { return true }
        if let hkError = error as? HKError {
            return hkError.code == .errorAuthorizationNotDetermined
                || hkError.code == .errorAuthorizationDenied
        }
        return false
    }

    /// 提交一次增量读取的 anchor（仅在用户确认导出后调用）。
    func commit(_ outcome: FetchOutcome) {
        for pending in outcome.pendingAnchors {
            anchorStore.saveArchivedAnchor(pending.anchorData, for: pending.metric)
        }
    }

    // MARK: 增量查询

    /// 返回归一化样本与新 anchor（归档为 Data），**不**落盘 anchor。
    private nonisolated func fetchIncremental(_ metric: HealthMetric,
                                              maxLookback: TimeInterval?) async throws -> ([HealthSample], Data?) {
        guard let type = metric.sampleType else { return ([], nil) }
        let storedAnchor = anchorStore.anchor(for: metric)
        let predicate = Self.lookbackPredicate(maxLookback)
        let (samples, newAnchor): ([HKSample], HKQueryAnchor?) = try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: storedAnchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples ?? [], newAnchor))
                }
            }
            healthStore.execute(query)
        }
        let anchorData = newAnchor.flatMap { AnchorStore.archive($0) }
        return (Self.convert(samples, metric: metric), anchorData)
    }

    // MARK: 日期段查询

    private nonisolated func fetchRange(_ metric: HealthMetric,
                                        start: Date?,
                                        end: Date?,
                                        maxLookback: TimeInterval?) async throws -> [HealthSample] {
        guard let type = metric.sampleType else { return [] }
        var effectiveStart = start
        if let maxLookback {
            let floor = Date().addingTimeInterval(-maxLookback)
            effectiveStart = max(start ?? floor, floor)
        }
        let predicate = HKQuery.predicateForSamples(withStart: effectiveStart, end: end, options: [.strictStartDate])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples = try await runSampleQuery(type, predicate: predicate,
                                               limit: HKObjectQueryNoLimit, sort: sort)
        return Self.convert(samples, metric: metric)
    }

    /// 通用样本查询封装。
    private nonisolated func runSampleQuery(_ type: HKSampleType,
                                            predicate: NSPredicate?,
                                            limit: Int,
                                            sort: [NSSortDescriptor]) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sort
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            healthStore.execute(query)
        }
    }

    private nonisolated static func lookbackPredicate(_ maxLookback: TimeInterval?) -> NSPredicate? {
        guard let maxLookback else { return nil }
        let start = Date().addingTimeInterval(-maxLookback)
        return HKQuery.predicateForSamples(withStart: start, end: nil, options: [.strictStartDate])
    }

    // MARK: 归一化（按 kind 分派）

    nonisolated static func convert(_ samples: [HKSample], metric: HealthMetric) -> [HealthSample] {
        samples.compactMap { convertOne($0, metric: metric) }
    }

    private nonisolated static func convertOne(_ sample: HKSample, metric: HealthMetric) -> HealthSample? {
        func make(value: Double? = nil, string: String? = nil, extra: [JSONValue]? = nil) -> HealthSample {
            HealthSample(type: metric.rawValue,
                         category: metric.category.rawValue,
                         value: value,
                         stringValue: string,
                         unit: metric.unitString,
                         start: sample.startDate,
                         end: sample.endDate,
                         source: sample.sourceRevision.source.name,
                         uuid: sample.uuid.uuidString,
                         extra: extra)
        }

        switch metric.kind {
        case .quantity:
            guard let q = sample as? HKQuantitySample, let unit = metric.hkUnit else { return nil }
            return make(value: q.quantity.doubleValue(for: unit))

        case .category:
            guard let c = sample as? HKCategorySample else { return nil }
            return make(string: categoryValueName(metric: metric, rawValue: c.value))

        case .workout:
            guard let w = sample as? HKWorkout else { return nil }
            let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
            return make(string: workoutActivityName(w.workoutActivityType),
                        extra: [kcal.map(JSONValue.number) ?? .null,
                                workoutDistanceKm(w).map(JSONValue.number) ?? .null])

        case .stateOfMind:
            guard let s = sample as? HKStateOfMind else { return nil }
            return make(value: s.valence,
                        extra: [.string(stateOfMindKindName(s.kind)),
                                .string(valenceClassificationName(s.valenceClassification)),
                                .array(s.labels.map { .string(stateOfMindLabelName($0)) }),
                                .array(s.associations.map { .string(stateOfMindAssociationName($0)) })])

        case .electrocardiogram:
            guard let e = sample as? HKElectrocardiogram else { return nil }
            let bpm = e.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            let hz = e.samplingFrequency?.doubleValue(for: .hertz())
            return make(string: ecgClassificationName(e.classification),
                        extra: [bpm.map(JSONValue.number) ?? .null,
                                hz.map(JSONValue.number) ?? .null,
                                .number(Double(e.numberOfVoltageMeasurements))])

        case .audiogram:
            guard let a = sample as? HKAudiogramSample else { return nil }
            let dBHL = HKUnit.decibelHearingLevel()
            let points: [JSONValue] = a.sensitivityPoints.map { point in
                func sensitivity(_ side: HKAudiogramSensitivityTestSide) -> JSONValue {
                    point.tests.first { $0.side == side }
                        .map { .number($0.sensitivity.doubleValue(for: dBHL)) } ?? .null
                }
                return .array([.number(point.frequency.doubleValue(for: .hertz())),
                               sensitivity(.left), sensitivity(.right)])
            }
            return make(value: Double(a.sensitivityPoints.count), extra: [.array(points)])

        case .scoredAssessment:
            guard let s = sample as? HKScoredAssessment else { return nil }
            let risk: String?
            if let gad7 = s as? HKGAD7Assessment {
                risk = gad7RiskName(gad7.risk)
            } else if let phq9 = s as? HKPHQ9Assessment {
                risk = phq9RiskName(phq9.risk)
            } else {
                risk = nil
            }
            return make(value: Double(s.score), extra: [risk.map(JSONValue.string) ?? .null])

        case .visionPrescription:
            guard let v = sample as? HKVisionPrescription else { return nil }
            return make(string: visionPrescriptionTypeName(v.prescriptionType),
                        extra: [.string(isoDateString(v.dateIssued)),
                                v.expirationDate.map { .string(isoDateString($0)) } ?? .null])

        case .medicationDose:
            guard let m = sample as? HKMedicationDoseEvent else { return nil }
            return make(string: medicationLogStatusName(m.logStatus),
                        extra: [.string(String(describing: m.medicationConceptIdentifier)),
                                m.doseQuantity.map(JSONValue.number) ?? .null,
                                .string(m.unit.unitString)])
        }
    }

    /// 体能训练总距离：按运动形态依次尝试各距离统计，取首个有值的（单位 km）。
    private nonisolated static func workoutDistanceKm(_ workout: HKWorkout) -> Double? {
        let candidates: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair,
            .distanceRowing, .distancePaddleSports, .distanceCrossCountrySkiing,
            .distanceDownhillSnowSports, .distanceSkatingSports,
        ]
        for identifier in candidates {
            if let sum = workout.statistics(for: HKQuantityType(identifier))?.sumQuantity() {
                return sum.doubleValue(for: .meterUnit(with: .kilo))
            }
        }
        return nil
    }

    private nonisolated static func isoDateString(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    // MARK: - 值名称表

    /// category 样本取值 → 可读字符串。已知值枚举显式映射；
    /// 事件型 notApplicable(0) → "occurred"；未知回退 "value<N>"。
    nonisolated static func categoryValueName(metric: HealthMetric, rawValue: Int) -> String {
        switch metric.rawValue {
        case "sleepAnalysis":
            return sleepStageName(rawValue)
        case "appetiteChanges":
            return name(rawValue, ["unspecified", "noChange", "decreased", "increased"], base: 0)
        case "moodChanges", "sleepChanges":
            return name(rawValue, ["present", "notPresent"], base: 0)
        case "menstrualFlow":
            return name(rawValue, ["unspecified", "light", "medium", "heavy", "none"], base: 1)
        case "cervicalMucusQuality":
            return name(rawValue, ["dry", "sticky", "creamy", "watery", "eggWhite"], base: 1)
        case "ovulationTestResult":
            return name(rawValue, ["negative", "luteinizingHormoneSurge", "indeterminate", "estrogenSurge"], base: 1)
        case "pregnancyTestResult", "progesteroneTestResult":
            return name(rawValue, ["negative", "positive", "indeterminate"], base: 1)
        case "contraceptive":
            return name(rawValue, ["unspecified", "implant", "injection", "intrauterineDevice",
                                   "intravaginalRing", "oral", "patch"], base: 1)
        case "appleStandHour":
            return name(rawValue, ["stood", "idle"], base: 0)
        case "appleWalkingSteadinessEvent":
            return name(rawValue, ["initialLow", "initialVeryLow", "repeatLow", "repeatVeryLow"], base: 1)
        case "environmentalAudioExposureEvent":
            return name(rawValue, ["momentaryLimit"], base: 1)
        case "headphoneAudioExposureEvent":
            return name(rawValue, ["sevenDayLimit"], base: 1)
        case "lowCardioFitnessEvent":
            return name(rawValue, ["lowFitness"], base: 1)
        default:
            if metric.category == .symptoms {
                return name(rawValue, ["unspecified", "notPresent", "mild", "moderate", "severe"], base: 0)
            }
            return rawValue == 0 ? "occurred" : "value\(rawValue)"
        }
    }

    /// 按枚举起始值取名；越界回退 "value<N>"。
    private nonisolated static func name(_ rawValue: Int, _ names: [String], base: Int) -> String {
        let index = rawValue - base
        guard names.indices.contains(index) else { return "value\(rawValue)" }
        return names[index]
    }

    /// 将 HKCategoryValueSleepAnalysis 原始值映射为可读字符串。
    private nonisolated static func sleepStageName(_ rawValue: Int) -> String {
        guard let stage = HKCategoryValueSleepAnalysis(rawValue: rawValue) else { return "unknown" }
        switch stage {
        case .inBed:             return "inBed"
        case .asleepUnspecified: return "asleepUnspecified"
        case .awake:             return "awake"
        case .asleepCore:        return "asleepCore"
        case .asleepDeep:        return "asleepDeep"
        case .asleepREM:         return "asleepREM"
        @unknown default:        return "unknown"
        }
    }

    nonisolated static func workoutActivityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .americanFootball:              return "americanFootball"
        case .archery:                       return "archery"
        case .australianFootball:            return "australianFootball"
        case .badminton:                     return "badminton"
        case .barre:                         return "barre"
        case .baseball:                      return "baseball"
        case .basketball:                    return "basketball"
        case .bowling:                       return "bowling"
        case .boxing:                        return "boxing"
        case .cardioDance:                   return "cardioDance"
        case .climbing:                      return "climbing"
        case .cooldown:                      return "cooldown"
        case .coreTraining:                  return "coreTraining"
        case .cricket:                       return "cricket"
        case .crossCountrySkiing:            return "crossCountrySkiing"
        case .crossTraining:                 return "crossTraining"
        case .curling:                       return "curling"
        case .cycling:                       return "cycling"
        case .discSports:                    return "discSports"
        case .downhillSkiing:                return "downhillSkiing"
        case .elliptical:                    return "elliptical"
        case .equestrianSports:              return "equestrianSports"
        case .fencing:                       return "fencing"
        case .fishing:                       return "fishing"
        case .fitnessGaming:                 return "fitnessGaming"
        case .flexibility:                   return "flexibility"
        case .functionalStrengthTraining:    return "functionalStrengthTraining"
        case .golf:                          return "golf"
        case .gymnastics:                    return "gymnastics"
        case .handball:                      return "handball"
        case .handCycling:                   return "handCycling"
        case .highIntensityIntervalTraining: return "highIntensityIntervalTraining"
        case .hiking:                        return "hiking"
        case .hockey:                        return "hockey"
        case .hunting:                       return "hunting"
        case .jumpRope:                      return "jumpRope"
        case .kickboxing:                    return "kickboxing"
        case .lacrosse:                      return "lacrosse"
        case .martialArts:                   return "martialArts"
        case .mindAndBody:                   return "mindAndBody"
        case .mixedCardio:                   return "mixedCardio"
        case .other:                         return "other"
        case .paddleSports:                  return "paddleSports"
        case .pickleball:                    return "pickleball"
        case .pilates:                       return "pilates"
        case .play:                          return "play"
        case .preparationAndRecovery:        return "preparationAndRecovery"
        case .racquetball:                   return "racquetball"
        case .rowing:                        return "rowing"
        case .rugby:                         return "rugby"
        case .running:                       return "running"
        case .sailing:                       return "sailing"
        case .skatingSports:                 return "skatingSports"
        case .snowboarding:                  return "snowboarding"
        case .snowSports:                    return "snowSports"
        case .soccer:                        return "soccer"
        case .socialDance:                   return "socialDance"
        case .softball:                      return "softball"
        case .squash:                        return "squash"
        case .stairClimbing:                 return "stairClimbing"
        case .stairs:                        return "stairs"
        case .stepTraining:                  return "stepTraining"
        case .surfingSports:                 return "surfingSports"
        case .swimBikeRun:                   return "swimBikeRun"
        case .swimming:                      return "swimming"
        case .tableTennis:                   return "tableTennis"
        case .taiChi:                        return "taiChi"
        case .tennis:                        return "tennis"
        case .trackAndField:                 return "trackAndField"
        case .traditionalStrengthTraining:   return "traditionalStrengthTraining"
        case .transition:                    return "transition"
        case .underwaterDiving:              return "underwaterDiving"
        case .volleyball:                    return "volleyball"
        case .walking:                       return "walking"
        case .waterFitness:                  return "waterFitness"
        case .waterPolo:                     return "waterPolo"
        case .waterSports:                   return "waterSports"
        case .wheelchairRunPace:             return "wheelchairRunPace"
        case .wheelchairWalkPace:            return "wheelchairWalkPace"
        case .wrestling:                     return "wrestling"
        case .yoga:                          return "yoga"
        default:
            // 已废弃 case（dance 等）与未来新增统一走 rawValue 回退，避免引用废弃符号。
            return legacyWorkoutNames[type.rawValue] ?? "activity\(type.rawValue)"
        }
    }

    private nonisolated static let legacyWorkoutNames: [UInt: String] = [
        14: "dance", 15: "danceInspiredTraining", 30: "mixedMetabolicCardioTraining",
    ]

    private nonisolated static func stateOfMindKindName(_ kind: HKStateOfMind.Kind) -> String {
        switch kind {
        case .momentaryEmotion: return "momentaryEmotion"
        case .dailyMood:        return "dailyMood"
        @unknown default:       return "unknown"
        }
    }

    private nonisolated static func valenceClassificationName(_ value: HKStateOfMind.ValenceClassification) -> String {
        switch value {
        case .veryUnpleasant:     return "veryUnpleasant"
        case .unpleasant:         return "unpleasant"
        case .slightlyUnpleasant: return "slightlyUnpleasant"
        case .neutral:            return "neutral"
        case .slightlyPleasant:   return "slightlyPleasant"
        case .pleasant:           return "pleasant"
        case .veryPleasant:       return "veryPleasant"
        @unknown default:         return "unknown"
        }
    }

    private nonisolated static func stateOfMindLabelName(_ label: HKStateOfMind.Label) -> String {
        switch label {
        case .amazed:       return "amazed"
        case .amused:       return "amused"
        case .angry:        return "angry"
        case .annoyed:      return "annoyed"
        case .anxious:      return "anxious"
        case .ashamed:      return "ashamed"
        case .brave:        return "brave"
        case .calm:         return "calm"
        case .confident:    return "confident"
        case .content:      return "content"
        case .disappointed: return "disappointed"
        case .discouraged:  return "discouraged"
        case .disgusted:    return "disgusted"
        case .drained:      return "drained"
        case .embarrassed:  return "embarrassed"
        case .excited:      return "excited"
        case .frustrated:   return "frustrated"
        case .grateful:     return "grateful"
        case .guilty:       return "guilty"
        case .happy:        return "happy"
        case .hopeful:      return "hopeful"
        case .hopeless:     return "hopeless"
        case .indifferent:  return "indifferent"
        case .irritated:    return "irritated"
        case .jealous:      return "jealous"
        case .joyful:       return "joyful"
        case .lonely:       return "lonely"
        case .overwhelmed:  return "overwhelmed"
        case .passionate:   return "passionate"
        case .peaceful:     return "peaceful"
        case .proud:        return "proud"
        case .relieved:     return "relieved"
        case .sad:          return "sad"
        case .satisfied:    return "satisfied"
        case .scared:       return "scared"
        case .stressed:     return "stressed"
        case .surprised:    return "surprised"
        case .worried:      return "worried"
        @unknown default:   return "unknown"
        }
    }

    private nonisolated static func stateOfMindAssociationName(_ value: HKStateOfMind.Association) -> String {
        switch value {
        case .community:     return "community"
        case .currentEvents: return "currentEvents"
        case .dating:        return "dating"
        case .education:     return "education"
        case .family:        return "family"
        case .fitness:       return "fitness"
        case .friends:       return "friends"
        case .health:        return "health"
        case .hobbies:       return "hobbies"
        case .identity:      return "identity"
        case .money:         return "money"
        case .partner:       return "partner"
        case .selfCare:      return "selfCare"
        case .spirituality:  return "spirituality"
        case .tasks:         return "tasks"
        case .travel:        return "travel"
        case .weather:       return "weather"
        case .work:          return "work"
        @unknown default:    return "unknown"
        }
    }

    private nonisolated static func ecgClassificationName(_ value: HKElectrocardiogram.Classification) -> String {
        switch value {
        case .notSet:                    return "notSet"
        case .sinusRhythm:               return "sinusRhythm"
        case .atrialFibrillation:        return "atrialFibrillation"
        case .inconclusiveLowHeartRate:  return "inconclusiveLowHeartRate"
        case .inconclusiveHighHeartRate: return "inconclusiveHighHeartRate"
        case .inconclusivePoorReading:   return "inconclusivePoorReading"
        case .inconclusiveOther:         return "inconclusiveOther"
        case .unrecognized:              return "unrecognized"
        @unknown default:                return "unknown"
        }
    }

    private nonisolated static func gad7RiskName(_ risk: HKGAD7Assessment.Risk) -> String {
        switch risk {
        case .noneToMinimal: return "noneToMinimal"
        case .mild:          return "mild"
        case .moderate:      return "moderate"
        case .severe:        return "severe"
        @unknown default:    return "unknown"
        }
    }

    private nonisolated static func phq9RiskName(_ risk: HKPHQ9Assessment.Risk) -> String {
        switch risk {
        case .noneToMinimal:    return "noneToMinimal"
        case .mild:             return "mild"
        case .moderate:         return "moderate"
        case .moderatelySevere: return "moderatelySevere"
        case .severe:           return "severe"
        @unknown default:       return "unknown"
        }
    }

    private nonisolated static func visionPrescriptionTypeName(_ value: HKVisionPrescriptionType) -> String {
        switch value {
        case .glasses:    return "glasses"
        case .contacts:   return "contacts"
        @unknown default: return "unknown"
        }
    }

    private nonisolated static func medicationLogStatusName(_ value: HKMedicationDoseEvent.LogStatus) -> String {
        switch value {
        case .taken:               return "taken"
        case .skipped:             return "skipped"
        case .snoozed:             return "snoozed"
        case .notLogged:           return "notLogged"
        case .notInteracted:       return "notInteracted"
        case .notificationNotSent: return "notificationNotSent"
        @unknown default:          return "unknown"
        }
    }

    private nonisolated static func biologicalSexName(_ value: HKBiologicalSex) -> String? {
        switch value {
        case .notSet:     return nil
        case .female:     return "female"
        case .male:       return "male"
        case .other:      return "other"
        @unknown default: return nil
        }
    }

    private nonisolated static func bloodTypeName(_ value: HKBloodType) -> String? {
        switch value {
        case .notSet:     return nil
        case .aPositive:  return "aPositive"
        case .aNegative:  return "aNegative"
        case .bPositive:  return "bPositive"
        case .bNegative:  return "bNegative"
        case .abPositive: return "abPositive"
        case .abNegative: return "abNegative"
        case .oPositive:  return "oPositive"
        case .oNegative:  return "oNegative"
        @unknown default: return nil
        }
    }

    private nonisolated static func skinTypeName(_ value: HKFitzpatrickSkinType) -> String? {
        switch value {
        case .notSet:     return nil
        case .I:          return "typeI"
        case .II:         return "typeII"
        case .III:        return "typeIII"
        case .IV:         return "typeIV"
        case .V:          return "typeV"
        case .VI:         return "typeVI"
        @unknown default: return nil
        }
    }

    private nonisolated static func wheelchairUseName(_ value: HKWheelchairUse) -> String? {
        switch value {
        case .notSet:     return nil
        case .no:         return "no"
        case .yes:        return "yes"
        @unknown default: return nil
        }
    }

    private nonisolated static func activityMoveModeName(_ value: HKActivityMoveMode) -> String? {
        switch value {
        case .activeEnergy:  return "activeEnergy"
        case .appleMoveTime: return "appleMoveTime"
        @unknown default:    return nil
        }
    }
}
#endif
