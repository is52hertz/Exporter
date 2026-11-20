import Foundation
import HealthKit
import Testing
@testable import Exporter

@MainActor
struct BackgroundPushTests {
    @Test func optInDefaultsOffAndPersists() throws {
        let suite = "BackgroundPushTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.backgroundPushEnabled)
        settings.backgroundPushEnabled = true
        #expect(AppSettings(defaults: defaults).backgroundPushEnabled)
        settings.backgroundPushEnabled = false
        #expect(!AppSettings(defaults: defaults).backgroundPushEnabled)
    }

    @Test func manualAndBackgroundCursorsAreIndependent() throws {
        let suite = "BackgroundPushTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let metric = try #require(HealthMetric(rawValue: "stepCount"))
        let manual = AnchorStore(defaults: defaults)
        let background = AnchorStore(defaults: defaults, keyPrefix: "backgroundAnchor")
        let manualAnchor = HKQueryAnchor(fromValue: 3)
        let backgroundAnchor = HKQueryAnchor(fromValue: 7)

        manual.save(manualAnchor, for: metric)
        #expect(background.anchor(for: metric) == nil)
        background.save(backgroundAnchor, for: metric)
        #expect(manual.anchor(for: metric) == manualAnchor)
        #expect(background.anchor(for: metric) == backgroundAnchor)
    }

    @Test func optOutCompletesWithoutFetching() async throws {
        let fixture = try Fixture()
        fixture.configuration = nil
        await fixture.notify()?.value
        #expect(fixture.events == ["complete"])
    }

    @Test func burstSendsOnceAndCommitsOnlyAfterPrimarySuccessWithoutBackup() async throws {
        let fixture = try Fixture()
        let batch = fixture.notify()
        fixture.notify()
        fixture.notify()
        await batch?.value
        #expect(fixture.events == ["fetch", "send", "commit", "complete", "complete", "complete"])
        fixture.expectProgress(advanced: true, receipt: fixture.receipt)
    }

    @Test func backupSuccessCommitsBackgroundAnchorAndSavesReceipt() async throws {
        let fixture = try Fixture()
        fixture.setBackup("http://192.168.1.2/health")
        fixture.receipt = .init(destination: .backup, host: "192.168.1.2")
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "send", "commit", "complete"])
        fixture.expectProgress(advanced: true, receipt: fixture.receipt)
    }

    @Test(arguments: [SenderError.httpStatus(500, body: nil), .unconfirmedDelivery])
    func failedSendKeepsAnchorsAndReceiptForNextWake(error: SenderError) async throws {
        let fixture = try Fixture()
        fixture.setBackup("https://backup.example.test/health")
        let previous = SendReceipt(destination: .backup, host: "previous.example.test")
        fixture.settings.lastSendReceipt = previous
        fixture.sendError = error
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "send", "complete"])
        fixture.expectProgress(advanced: false, receipt: previous)

        fixture.sendError = nil
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "send", "complete", "fetch", "send", "commit", "complete"])
        fixture.expectProgress(advanced: true, receipt: fixture.receipt)
    }

    @Test func emptyFetchDoesNotSendOrCommit() async throws {
        let fixture = try Fixture()
        fixture.hasSamples = false
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "complete"])
    }

    @Test func disablingDuringFetchDoesNotSendOrCommit() async throws {
        let fixture = try Fixture()
        fixture.onFetch = { [unowned fixture] in
            fixture.configuration = nil
            fixture.push.cancel()
        }
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "complete"])
    }

    @Test func backupEditDuringFetchDoesNotSend() async throws {
        let fixture = try Fixture()
        fixture.onFetch = { [unowned fixture] in
            fixture.setBackup("https://backup.example.test/health")
        }
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "complete"])
        fixture.expectProgress(advanced: false, receipt: nil)
    }

    @Test func backupEditDuringSendDiscardsStaleSuccess() async throws {
        let fixture = try Fixture()
        fixture.setBackup("https://backup.example.test/health")
        fixture.receipt = .init(destination: .backup, host: "backup.example.test")
        fixture.onSend = { [unowned fixture] in fixture.setBackup("https://other.example.test/health") }
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "send", "complete"])
        fixture.expectProgress(advanced: false, receipt: nil)
    }

    @Test func cancelDuringSendDiscardsSuccessEvenIfConfigurationMatches() async throws {
        let fixture = try Fixture()
        fixture.onSend = { [unowned fixture] in fixture.push.cancel() }
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "send", "complete"])
        fixture.expectProgress(advanced: false, receipt: nil)
    }

    @Test func pendingEndpointDraftIsInvisibleToBackgroundNotification() async throws {
        let fixture = try Fixture()
        fixture.useSavedSettings()
        var draft = fixture.settings.endpointDraft
        draft.endpoint = "https://draft.example.test/health"
        draft.backupEndpoint = "http://192.168.1.2/health"
        draft.authorizationHeader = "Bearer draft-fixture"

        await fixture.notify()?.value

        #expect(fixture.postHosts == ["example.test", "saved.example.test"])
        #expect(fixture.postAuthorization == ["Bearer saved-fixture", "Bearer saved-fixture"])
        fixture.expectProgress(advanced: true, receipt: .init(destination: .backup, host: "saved.example.test"))
        #expect(fixture.settings.endpointDraft != draft)
    }

    @Test(arguments: [false, true])
    func revokedConfigurationCannotStartBackup(switchAddress: Bool) async throws {
        let fixture = try Fixture()
        fixture.useSavedSettings()
        fixture.duringPrimaryPOST = { [unowned fixture] in
            if switchAddress {
                var draft = fixture.settings.endpointDraft
                draft.backupEndpoint = "https://replacement.example.test/health"
                #expect(fixture.settings.applyEndpointDraft(draft))
            } else {
                fixture.settings.backgroundPushEnabled = false
            }
        }

        await fixture.notify()?.value

        #expect(fixture.postHosts == ["example.test"])
        #expect(fixture.events == ["fetch", "complete"])
        fixture.expectProgress(advanced: false, receipt: nil)
    }

    @MainActor
    private final class Fixture {
        private let metric = HealthMetric(rawValue: "stepCount")!
        private let suite = "BackgroundPushTests-\(UUID())"
        private let defaults: UserDefaults
        private let manual: AnchorStore
        private let background: AnchorStore
        private let pendingAnchorData: Data
        let settings: AppSettings
        var configuration: BackgroundPush.Configuration?
        var events: [String] = []
        var hasSamples = true
        var sendError: SenderError?
        var receipt: SendReceipt = .init(destination: .primary, host: "example.test")
        var onFetch: (() -> Void)?
        var onSend: (() -> Void)?
        var duringPrimaryPOST: (() -> Void)?
        var postHosts: [String] = []
        var postAuthorization: [String] = []
        private var usesSavedSettings = false
        private lazy var delivery = BackgroundDelivery(settings: settings, health: HealthKitManager())

        func useSavedSettings() {
            usesSavedSettings = true
            settings.selectedMetrics = [metric]
            var draft = settings.endpointDraft
            draft.endpoint = "https://example.test/health"
            draft.backupEndpoint = "https://saved.example.test/health"
            draft.authorizationHeader = "Bearer saved-fixture"
            #expect(settings.applyEndpointDraft(draft))
            settings.backgroundPushEnabled = true
            // Same synchronous invalidation hook as production, but intentionally never call
            // the deferred refresh/cancel. This exercises the gap it cannot guard by itself.
            _ = push.trackConfiguration { delivery.currentConfiguration() }
        }

        private func attemptPOST(_ request: URLRequest) -> POSTOutcome {
            let url = request.url!
            postHosts.append(url.host ?? "")
            postAuthorization.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if url.host == "example.test" {
                // Revoke or replace settings while the primary is in flight, before returning
                // a failure which otherwise authorizes a backup attempt.
                duringPrimaryPOST?()
                let evidence = POSTAttemptSummary(metricsReports: [.init(transactions: [.init(fetchType: .networkLoad)])])
                return .failure(URLError(.cannotConnectToHost), evidence)
            }
            return .response(Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            settings = AppSettings(defaults: defaults)
            manual = AnchorStore(defaults: defaults)
            background = AnchorStore(defaults: defaults, keyPrefix: "backgroundAnchor")
            pendingAnchorData = try #require(AnchorStore.archive(HKQueryAnchor(fromValue: 7)))
            manual.save(HKQueryAnchor(fromValue: 3), for: metric)
            background.save(HKQueryAnchor(fromValue: 5), for: metric)
            setBackup("")
        }

        deinit {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }

        func setBackup(_ backupEndpoint: String) {
            configuration = .init(metrics: [metric], endpoint: "https://example.test/health",
                                  backupEndpoint: backupEndpoint, authorizationHeader: "", includeUUID: true)
        }

        func expectProgress(advanced: Bool, receipt: SendReceipt?) {
            #expect(manual.anchor(for: metric) == HKQueryAnchor(fromValue: 3))
            #expect(background.anchor(for: metric) == HKQueryAnchor(fromValue: advanced ? 7 : 5))
            #expect(settings.lastSendReceipt == receipt)
            #expect(AppSettings(defaults: defaults).lastSendReceipt == receipt)
        }

        lazy var push = BackgroundPush(
            configuration: { [unowned self] in usesSavedSettings ? delivery.currentConfiguration() : configuration },
            fetch: { [unowned self] metrics in
                #expect(metrics == [metric])
                events.append("fetch")
                onFetch?()
                let now = Date(timeIntervalSince1970: 1_700_000_000)
                let sample = HealthSample(type: metric.rawValue, category: metric.category.rawValue, value: 42,
                                          stringValue: nil, unit: "count", start: now, end: now,
                                          source: "Test", uuid: "test-sample")
                return .init(samples: hasSamples ? [sample] : [],
                             pendingAnchors: [.init(metric: metric, anchorData: pendingAnchorData)],
                             isIncremental: true, skippedMetrics: [])
            },
            sender: { [unowned self] config, startAuthorization in
                if usesSavedSettings {
                    let sender = BackgroundDelivery.makeSender(config, startAuthorization: startAuthorization)
                    return RoutedSender(sender: sender, attempt: { [weak self] request, _ in
                        guard let self else { return .failure(CancellationError(), .init()) }
                        return await self.attemptPOST(request)
                    })
                }
                return FakeSender { data in
                    #expect(String(decoding: data, as: UTF8.self).contains("test-sample"))
                    self.events.append("send")
                    self.onSend?()
                    if let error = self.sendError { throw error }
                    return self.receipt
                }
            },
            commit: { [unowned self] outcome, receipt in
                for anchor in outcome.pendingAnchors {
                    background.saveArchivedAnchor(anchor.anchorData, for: anchor.metric)
                }
                settings.lastSendReceipt = receipt
                events.append("commit")
            },
            device: .init(model: "Simulator", os: "iOS"),
            batchingDelay: .zero)

        @discardableResult
        func notify() -> Task<Void, Never>? {
            push.notify { [unowned self] in events.append("complete") }
        }
    }

    /// 后台推送走 HTTPSender，会话是全进程共用、拒绝一切重定向的 backgroundSession，
    /// 并保留后台的 15 秒 / 20 秒时限；手动发送的会话时限不受影响。
    @Test(arguments: ["", "http://192.168.1.2/hook"])
    func backgroundSenderUsesSharedNoRedirectSession(backupEndpoint: String) {
        let config = BackgroundPush.Configuration(metrics: [], endpoint: "https://a.example/hook",
                                                  backupEndpoint: backupEndpoint,
                                                  authorizationHeader: "Bearer t", includeUUID: false)
        let first = BackgroundDelivery.makeSender(config)
        let second = BackgroundDelivery.makeSender(config)
        #expect(first.session === HTTPSender.backgroundSession)
        #expect(second.session === first.session, "每次推送都复用同一个会话")
        #expect(first.endpoint == config.endpoint)
        #expect(first.backupEndpoint == config.backupEndpoint)
        #expect(first.authorizationHeader == config.authorizationHeader)
        #expect(first.session.delegate is NoRedirectDelegate)
        #expect(first.session.configuration.timeoutIntervalForRequest == 15)
        #expect(first.session.configuration.timeoutIntervalForResource == 20)
        #expect(HTTPSender.secureSession !== HTTPSender.backgroundSession)
        #expect(HTTPSender.secureSession.delegate is NoRedirectDelegate)
        #expect(HTTPSender.secureSession.configuration.timeoutIntervalForResource > 20,
                "手动大导出不套用后台短时限")
    }

    /// 后台注册前就用发送器的同一条规则校验地址：http、无主机都不算已配置，不注册监听。
    @Test func backgroundConfigurationRequiresHTTPSEndpoint() throws {
        let suite = "BackgroundPushTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.backgroundPushEnabled = true
        settings.selectedMetrics = [try #require(HealthMetric(rawValue: "stepCount"))]
        let delivery = BackgroundDelivery(settings: settings, health: HealthKitManager())
        for bad in ["http://a.example/hook", "https://", "ftp://a.example/x", ""] {
            settings.endpoint = bad
            #expect(delivery.currentConfiguration() == nil, "\(bad) 不应注册后台推送")
        }
        settings.endpoint = " \n https://a.example/hook \t"
        #expect(delivery.currentConfiguration()?.endpoint == "https://a.example/hook")
        #expect(delivery.currentConfiguration()?.backupEndpoint == "")

        settings.backupEndpoint = " \t\n "
        #expect(delivery.currentConfiguration()?.backupEndpoint == "")
        for invalid in ["http://public.example/hook", "https://", "ftp://box.local/hook"] {
            settings.backupEndpoint = invalid
            #expect(delivery.currentConfiguration() == nil)
        }
        for valid in ["https://backup.example/hook", "http://192.168.1.2/hook", "http://box.local/hook"] {
            settings.backupEndpoint = " \t\(valid)\n"
            #expect(delivery.currentConfiguration()?.backupEndpoint == valid)
        }
        settings.endpoint = ""
        #expect(delivery.currentConfiguration() == nil, "备用地址不能替代未配置的主地址")
    }

    /// 后台会话的重定向回调：跨主机 https 与降级到 http 都拿到 nil，不发后续请求。
    @Test func backgroundSessionRefusesRedirects() throws {
        let session = HTTPSender.backgroundSession
        let delegate = try #require(session.delegate as? NoRedirectDelegate)
        let task = session.dataTask(with: URL(string: "https://a.example/hook")!)
        defer { task.cancel() }
        for target in ["https://b.example/steal", "http://a.example/hook"] {
            let resp = HTTPURLResponse(url: URL(string: "https://a.example/hook")!, statusCode: 307,
                                       httpVersion: nil, headerFields: ["Location": target])!
            var followed: URLRequest? = URLRequest(url: URL(string: "https://sentinel.example")!)
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: resp,
                                newRequest: URLRequest(url: URL(string: target)!)) { followed = $0 }
            #expect(followed == nil, "后台推送重定向到 \(target) 不应被跟随")
        }
    }

    private nonisolated struct RoutedSender: ExportSender {
        let sender: HTTPSender
        let attempt: @Sendable (URLRequest, URLSession) async -> POSTOutcome

        func send(_ data: Data) async throws -> SendReceipt {
            try await sender.send(data, attempt: attempt)
        }
    }

    private nonisolated struct FakeSender: ExportSender {
        let operation: @MainActor @Sendable (Data) throws -> SendReceipt

        func send(_ data: Data) async throws -> SendReceipt {
            try await operation(data)
        }
    }
}
