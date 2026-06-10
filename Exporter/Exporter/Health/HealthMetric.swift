//
//  HealthMetric.swift
//  Exporter
//
//  数据类型目录：覆盖 iOS 26.5 SDK 全部可读样本类型（120 quantity + 69 category + 8 特殊类型）。
//  数据驱动（struct + 静态注册表）而非枚举；rawValue = HK 标识符去前缀的短驼峰，
//  与 AnchorStore / 设置持久化的既有 key 兼容。
//  与 HKSampleType / HKUnit 的映射放在 HealthKitManager 的扩展中（仅 canImport(HealthKit) 平台）。
//  目录由 SDK 头文件 HKTypeIdentifiers.h 机械生成（单位取自头文件注释），中文名对照健康 App 官方术语。
//

import Foundation

/// 数据大类：对齐健康 App 浏览页分类，用于 JSON 分组与 UI 分区。
nonisolated enum HealthCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case activity       // 活动
    case workout        // 体能训练
    case body           // 身体测量
    case heart          // 心脏
    case mobility       // 行动能力
    case hearing        // 听觉
    case respiratory    // 呼吸
    case nutrition      // 营养
    case sleep          // 睡眠
    case cycleTracking  // 周期记录
    case symptoms       // 症状
    case mindfulness    // 心理健康
    case medications    // 用药
    case other          // 其他数据

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .activity:      return "活动"
        case .workout:       return "体能训练"
        case .body:          return "身体测量"
        case .heart:         return "心脏"
        case .mobility:      return "行动能力"
        case .hearing:       return "听觉"
        case .respiratory:   return "呼吸"
        case .nutrition:     return "营养"
        case .sleep:         return "睡眠"
        case .cycleTracking: return "周期记录"
        case .symptoms:      return "症状"
        case .mindfulness:   return "心理健康"
        case .medications:   return "用药"
        case .other:         return "其他数据"
        }
    }

    var systemImage: String {
        switch self {
        case .activity:      return "flame.fill"
        case .workout:       return "figure.run"
        case .body:          return "figure"
        case .heart:         return "heart.fill"
        case .mobility:      return "figure.walk.motion"
        case .hearing:       return "ear"
        case .respiratory:   return "lungs.fill"
        case .nutrition:     return "fork.knife"
        case .sleep:         return "bed.double.fill"
        case .cycleTracking: return "calendar.circle"
        case .symptoms:      return "stethoscope"
        case .mindfulness:   return "brain.head.profile"
        case .medications:   return "pills.fill"
        case .other:         return "ellipsis.circle"
        }
    }
}

/// 单个健康指标的描述符。新增指标只需在注册表中添加一行。
nonisolated struct HealthMetric: Hashable, Identifiable, Sendable {
    /// 样本形态：数值 / 分类 / 各特殊样本类型。
    enum Kind: Hashable, Sendable {
        case quantity
        case category
        case workout
        case stateOfMind
        case electrocardiogram
        case audiogram
        case scoredAssessment   // GAD-7 / PHQ-9（按 rawValue 区分）
        case visionPrescription
        case medicationDose
    }

    /// 稳定标识：HK 标识符去前缀（如 "stepCount"），写入 JSON、anchor key 与设置持久化。
    let rawValue: String
    let kind: Kind
    let category: HealthCategory
    /// 官方中文名（健康 App 术语）。
    let displayName: String
    /// 写入 JSON 的单位字符串；仅 quantity 有。
    let unitString: String?

    var id: String { rawValue }
    var systemImage: String { category.systemImage }

    /// 特殊类型在 row 中除 [start, durationSec, value, source] 之外的附加列。
    var extraColumns: [String] {
        switch kind {
        case .workout:            return ["kcal", "distanceKm"]            // value = 运动类型
        case .stateOfMind:        return ["kind", "classification", "labels", "associations"] // value = 愉悦度
        case .electrocardiogram:  return ["avgBPM", "samplingHz", "voltagePoints"] // value = 分类结果
        case .audiogram:          return ["points"]                        // value = 测试点数；points = [[freqHz, 左耳dB?, 右耳dB?]]
        case .scoredAssessment:   return ["risk"]                          // value = 得分
        case .visionPrescription: return ["issued", "expires"]             // value = 处方类型
        case .medicationDose:     return ["concept", "dose", "doseUnit"]   // value = 记录状态
        case .quantity, .category: return []
        }
    }

    init?(rawValue: String) {
        guard let metric = Self.byRawValue[rawValue] else { return nil }
        self = metric
    }

    private init(_ rawValue: String, _ kind: Kind, _ category: HealthCategory,
                 _ displayName: String, unit: String? = nil) {
        self.rawValue = rawValue
        self.kind = kind
        self.category = category
        self.displayName = displayName
        self.unitString = unit
    }

    static let byRawValue: [String: HealthMetric] =
        Dictionary(uniqueKeysWithValues: registered.map { ($0.rawValue, $0) })

    // MARK: - 注册表

    private static func q(_ raw: String, _ unit: String, _ cat: HealthCategory, _ name: String) -> HealthMetric {
        HealthMetric(raw, .quantity, cat, name, unit: unit)
    }

    private static func c(_ raw: String, _ cat: HealthCategory, _ name: String) -> HealthMetric {
        HealthMetric(raw, .category, cat, name)
    }

    /// 全量注册指标（按分类分段；分类内大致按健康 App 顺序）。
    static let registered: [HealthMetric] =
        activity + workouts + body + heart + mobility + hearing + respiratory
        + nutrition + sleep + cycleTracking + symptoms + mindfulness + medications + other

    private static let activity: [HealthMetric] = [
        q("stepCount", "count", .activity, "步数"),
        q("distanceWalkingRunning", "m", .activity, "步行+跑步距离"),
        q("flightsClimbed", "count", .activity, "已爬楼层"),
        q("activeEnergyBurned", "kcal", .activity, "活动能量"),
        q("basalEnergyBurned", "kcal", .activity, "静息能量"),
        q("appleExerciseTime", "min", .activity, "锻炼时长"),
        q("appleStandTime", "min", .activity, "站立时长"),
        q("appleMoveTime", "min", .activity, "活动时长"),
        c("appleStandHour", .activity, "站立小时"),
        q("physicalEffort", "kcal/(kg*hr)", .activity, "身体强度"),
        q("workoutEffortScore", "appleEffortScore", .activity, "体能训练强度评分"),
        q("estimatedWorkoutEffortScore", "appleEffortScore", .activity, "预估体能训练强度评分"),
        q("runningSpeed", "m/s", .activity, "跑步速度"),
        q("runningPower", "W", .activity, "跑步功率"),
        q("runningStrideLength", "m", .activity, "跑步步幅"),
        q("runningGroundContactTime", "ms", .activity, "触地时间"),
        q("runningVerticalOscillation", "cm", .activity, "垂直振幅"),
        q("distanceCycling", "m", .activity, "骑行距离"),
        q("cyclingSpeed", "m/s", .activity, "骑行速度"),
        q("cyclingPower", "W", .activity, "骑行功率"),
        q("cyclingCadence", "count/min", .activity, "骑行踏频"),
        q("cyclingFunctionalThresholdPower", "W", .activity, "骑行功能阈值功率"),
        q("distanceSwimming", "m", .activity, "游泳距离"),
        q("swimmingStrokeCount", "count", .activity, "游泳划水次数"),
        q("underwaterDepth", "m", .activity, "水下深度"),
        q("distanceRowing", "m", .activity, "划船距离"),
        q("rowingSpeed", "m/s", .activity, "划船速度"),
        q("distancePaddleSports", "m", .activity, "桨类运动距离"),
        q("paddleSportsSpeed", "m/s", .activity, "桨类运动速度"),
        q("distanceCrossCountrySkiing", "m", .activity, "越野滑雪距离"),
        q("crossCountrySkiingSpeed", "m/s", .activity, "越野滑雪速度"),
        q("distanceDownhillSnowSports", "m", .activity, "下坡雪类运动距离"),
        q("distanceSkatingSports", "m", .activity, "滑冰运动距离"),
        q("distanceWheelchair", "m", .activity, "轮椅距离"),
        q("pushCount", "count", .activity, "轮椅推行次数"),
        q("nikeFuel", "count", .activity, "NikeFuel"),
    ]

    private static let workouts: [HealthMetric] = [
        HealthMetric("workout", .workout, .workout, "体能训练"),
    ]

    private static let body: [HealthMetric] = [
        q("height", "m", .body, "身高"),
        q("bodyMass", "kg", .body, "体重"),
        q("bodyMassIndex", "count", .body, "身体质量指数"),
        q("bodyFatPercentage", "%", .body, "体脂率"),
        q("leanBodyMass", "kg", .body, "去脂体重"),
        q("waistCircumference", "m", .body, "腰围"),
        q("bodyTemperature", "degC", .body, "体温"),
        q("appleSleepingWristTemperature", "degC", .body, "手腕温度"),
        q("electrodermalActivity", "S", .body, "皮肤电活动"),
    ]

    private static let heart: [HealthMetric] = [
        q("heartRate", "count/min", .heart, "心率"),
        q("restingHeartRate", "count/min", .heart, "静息心率"),
        q("walkingHeartRateAverage", "count/min", .heart, "步行平均心率"),
        q("heartRateVariabilitySDNN", "ms", .heart, "心率变异性"),
        q("heartRateRecoveryOneMinute", "count/min", .heart, "心率恢复"),
        q("atrialFibrillationBurden", "%", .heart, "房颤负荷"),
        q("peripheralPerfusionIndex", "%", .heart, "外周灌注指数"),
        q("vo2Max", "ml/(kg*min)", .heart, "心肺适能（最大摄氧量）"),
        q("bloodPressureSystolic", "mmHg", .heart, "收缩压"),
        q("bloodPressureDiastolic", "mmHg", .heart, "舒张压"),
        c("highHeartRateEvent", .heart, "高心率事件"),
        c("lowHeartRateEvent", .heart, "低心率事件"),
        c("irregularHeartRhythmEvent", .heart, "心律不齐事件"),
        c("lowCardioFitnessEvent", .heart, "心肺适能偏低事件"),
        c("hypertensionEvent", .heart, "高血压事件"),
        HealthMetric("electrocardiogram", .electrocardiogram, .heart, "心电图"),
    ]

    private static let mobility: [HealthMetric] = [
        q("walkingSpeed", "m/s", .mobility, "步行速度"),
        q("walkingStepLength", "m", .mobility, "步长"),
        q("walkingAsymmetryPercentage", "%", .mobility, "步行不对称性"),
        q("walkingDoubleSupportPercentage", "%", .mobility, "双脚支撑时间"),
        q("appleWalkingSteadiness", "%", .mobility, "步行稳定性"),
        c("appleWalkingSteadinessEvent", .mobility, "步行稳定性事件"),
        q("stairAscentSpeed", "m/s", .mobility, "上楼速度"),
        q("stairDescentSpeed", "m/s", .mobility, "下楼速度"),
        q("sixMinuteWalkTestDistance", "m", .mobility, "六分钟步行距离"),
    ]

    private static let hearing: [HealthMetric] = [
        q("environmentalAudioExposure", "dBASPL", .hearing, "环境音量"),
        q("headphoneAudioExposure", "dBASPL", .hearing, "耳机音量"),
        q("environmentalSoundReduction", "dBASPL", .hearing, "环境音降噪"),
        c("environmentalAudioExposureEvent", .hearing, "环境音量暴露事件"),
        c("headphoneAudioExposureEvent", .hearing, "耳机音量暴露事件"),
        HealthMetric("audiogram", .audiogram, .hearing, "听力图"),
    ]

    private static let respiratory: [HealthMetric] = [
        q("respiratoryRate", "count/min", .respiratory, "呼吸频率"),
        q("oxygenSaturation", "%", .respiratory, "血氧饱和度"),
        q("forcedExpiratoryVolume1", "L", .respiratory, "一秒用力呼气量"),
        q("forcedVitalCapacity", "L", .respiratory, "用力肺活量"),
        q("peakExpiratoryFlowRate", "L/min", .respiratory, "呼气流量峰值"),
        q("inhalerUsage", "count", .respiratory, "吸入器使用"),
        q("appleSleepingBreathingDisturbances", "count", .respiratory, "睡眠呼吸紊乱"),
        c("sleepApneaEvent", .respiratory, "睡眠呼吸暂停事件"),
    ]

    private static let nutrition: [HealthMetric] = [
        q("dietaryEnergyConsumed", "kcal", .nutrition, "膳食能量"),
        q("dietaryCarbohydrates", "g", .nutrition, "碳水化合物"),
        q("dietaryProtein", "g", .nutrition, "蛋白质"),
        q("dietaryFatTotal", "g", .nutrition, "总脂肪"),
        q("dietaryFatSaturated", "g", .nutrition, "饱和脂肪"),
        q("dietaryFatMonounsaturated", "g", .nutrition, "单不饱和脂肪"),
        q("dietaryFatPolyunsaturated", "g", .nutrition, "多不饱和脂肪"),
        q("dietaryCholesterol", "g", .nutrition, "膳食胆固醇"),
        q("dietaryFiber", "g", .nutrition, "膳食纤维"),
        q("dietarySugar", "g", .nutrition, "糖"),
        q("dietaryWater", "mL", .nutrition, "水"),
        q("dietaryCaffeine", "g", .nutrition, "咖啡因"),
        q("dietarySodium", "g", .nutrition, "钠"),
        q("dietaryPotassium", "g", .nutrition, "钾"),
        q("dietaryCalcium", "g", .nutrition, "钙"),
        q("dietaryIron", "g", .nutrition, "铁"),
        q("dietaryMagnesium", "g", .nutrition, "镁"),
        q("dietaryPhosphorus", "g", .nutrition, "磷"),
        q("dietaryZinc", "g", .nutrition, "锌"),
        q("dietaryCopper", "g", .nutrition, "铜"),
        q("dietaryManganese", "g", .nutrition, "锰"),
        q("dietarySelenium", "g", .nutrition, "硒"),
        q("dietaryChromium", "g", .nutrition, "铬"),
        q("dietaryMolybdenum", "g", .nutrition, "钼"),
        q("dietaryIodine", "g", .nutrition, "碘"),
        q("dietaryChloride", "g", .nutrition, "氯化物"),
        q("dietaryBiotin", "g", .nutrition, "生物素"),
        q("dietaryFolate", "g", .nutrition, "叶酸"),
        q("dietaryNiacin", "g", .nutrition, "烟酸"),
        q("dietaryPantothenicAcid", "g", .nutrition, "泛酸"),
        q("dietaryRiboflavin", "g", .nutrition, "核黄素（维生素 B2）"),
        q("dietaryThiamin", "g", .nutrition, "硫胺素（维生素 B1）"),
        q("dietaryVitaminA", "g", .nutrition, "维生素 A"),
        q("dietaryVitaminB6", "g", .nutrition, "维生素 B6"),
        q("dietaryVitaminB12", "g", .nutrition, "维生素 B12"),
        q("dietaryVitaminC", "g", .nutrition, "维生素 C"),
        q("dietaryVitaminD", "g", .nutrition, "维生素 D"),
        q("dietaryVitaminE", "g", .nutrition, "维生素 E"),
        q("dietaryVitaminK", "g", .nutrition, "维生素 K"),
    ]

    private static let sleep: [HealthMetric] = [
        c("sleepAnalysis", .sleep, "睡眠分析"),
    ]

    private static let cycleTracking: [HealthMetric] = [
        c("menstrualFlow", .cycleTracking, "月经"),
        c("intermenstrualBleeding", .cycleTracking, "经间期出血"),
        c("infrequentMenstrualCycles", .cycleTracking, "月经稀发"),
        c("irregularMenstrualCycles", .cycleTracking, "月经不规律"),
        c("persistentIntermenstrualBleeding", .cycleTracking, "持续性经间期出血"),
        c("prolongedMenstrualPeriods", .cycleTracking, "经期延长"),
        q("basalBodyTemperature", "degC", .cycleTracking, "基础体温"),
        c("cervicalMucusQuality", .cycleTracking, "宫颈粘液质量"),
        c("ovulationTestResult", .cycleTracking, "排卵测试结果"),
        c("pregnancyTestResult", .cycleTracking, "验孕结果"),
        c("progesteroneTestResult", .cycleTracking, "孕酮测试结果"),
        c("pregnancy", .cycleTracking, "怀孕"),
        c("bleedingDuringPregnancy", .cycleTracking, "孕期出血"),
        c("bleedingAfterPregnancy", .cycleTracking, "产后出血"),
        c("lactation", .cycleTracking, "哺乳"),
        c("contraceptive", .cycleTracking, "避孕"),
        c("sexualActivity", .cycleTracking, "性行为"),
    ]

    private static let symptoms: [HealthMetric] = [
        c("abdominalCramps", .symptoms, "腹部绞痛"),
        c("acne", .symptoms, "痤疮"),
        c("appetiteChanges", .symptoms, "食欲变化"),
        c("bladderIncontinence", .symptoms, "膀胱失禁"),
        c("bloating", .symptoms, "腹胀"),
        c("breastPain", .symptoms, "乳房疼痛"),
        c("chestTightnessOrPain", .symptoms, "胸闷或胸痛"),
        c("chills", .symptoms, "发冷"),
        c("constipation", .symptoms, "便秘"),
        c("coughing", .symptoms, "咳嗽"),
        c("diarrhea", .symptoms, "腹泻"),
        c("dizziness", .symptoms, "头晕"),
        c("drySkin", .symptoms, "皮肤干燥"),
        c("fainting", .symptoms, "昏厥"),
        c("fatigue", .symptoms, "疲劳"),
        c("fever", .symptoms, "发烧"),
        c("generalizedBodyAche", .symptoms, "全身疼痛"),
        c("hairLoss", .symptoms, "脱发"),
        c("headache", .symptoms, "头痛"),
        c("heartburn", .symptoms, "胃灼热"),
        c("hotFlashes", .symptoms, "潮热"),
        c("lossOfSmell", .symptoms, "嗅觉丧失"),
        c("lossOfTaste", .symptoms, "味觉丧失"),
        c("lowerBackPain", .symptoms, "腰痛"),
        c("memoryLapse", .symptoms, "记忆力减退"),
        c("moodChanges", .symptoms, "情绪变化"),
        c("nausea", .symptoms, "恶心"),
        c("nightSweats", .symptoms, "盗汗"),
        c("pelvicPain", .symptoms, "盆腔疼痛"),
        c("rapidPoundingOrFlutteringHeartbeat", .symptoms, "心跳加速或心悸"),
        c("runnyNose", .symptoms, "流鼻涕"),
        c("shortnessOfBreath", .symptoms, "呼吸急促"),
        c("sinusCongestion", .symptoms, "鼻窦充血"),
        c("skippedHeartbeat", .symptoms, "心跳漏拍"),
        c("sleepChanges", .symptoms, "睡眠变化"),
        c("soreThroat", .symptoms, "喉咙痛"),
        c("vaginalDryness", .symptoms, "阴道干燥"),
        c("vomiting", .symptoms, "呕吐"),
        c("wheezing", .symptoms, "喘息"),
    ]

    private static let mindfulness: [HealthMetric] = [
        c("mindfulSession", .mindfulness, "正念时刻"),
        HealthMetric("stateOfMind", .stateOfMind, .mindfulness, "心境"),
        HealthMetric("GAD7", .scoredAssessment, .mindfulness, "焦虑风险评估（GAD-7）"),
        HealthMetric("PHQ9", .scoredAssessment, .mindfulness, "抑郁风险评估（PHQ-9）"),
    ]

    private static let medications: [HealthMetric] = [
        HealthMetric("medicationDoseEvent", .medicationDose, .medications, "用药记录"),
    ]

    private static let other: [HealthMetric] = [
        q("bloodGlucose", "mg/dL", .other, "血糖"),
        q("insulinDelivery", "IU", .other, "胰岛素剂量"),
        q("bloodAlcoholContent", "%", .other, "血液酒精含量"),
        q("numberOfAlcoholicBeverages", "count", .other, "酒精饮品"),
        q("numberOfTimesFallen", "count", .other, "跌倒次数"),
        q("timeInDaylight", "min", .other, "阳光下时间"),
        q("uvExposure", "count", .other, "紫外线指数"),
        q("waterTemperature", "degC", .other, "水温"),
        c("handwashingEvent", .other, "洗手"),
        c("toothbrushingEvent", .other, "刷牙"),
        HealthMetric("visionPrescription", .visionPrescription, .other, "视力处方"),
    ]
}
