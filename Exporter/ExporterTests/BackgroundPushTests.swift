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

    @Test func optOutCompletesWithoutFetching() async {
        let fixture = Fixture()
        fixture.configuration = nil
        await fixture.notify()?.value
        #expect(fixture.events == ["complete"])
    }

    @Test func burstSendsOnceAndCommitsOnlyAfterSuccess() async {
        let fixture = Fixture()
        let batch = fixture.notify()
        fixture.notify()
        fixture.notify()
        await batch?.value
        #expect(fixture.events == ["fetch", "send", "commit", "complete", "complete", "complete"])
    }

    @Test func failedSendKeepsAnchorsForNextWake() async {
        let fixture = Fixture()
        fixture.shouldFail = true
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "send", "complete"])

        fixture.shouldFail = false
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "send", "complete", "fetch", "send", "commit", "complete"])
    }

    @Test func emptyFetchDoesNotSendOrCommit() async {
        let fixture = Fixture()
        fixture.hasSamples = false
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "complete"])
    }

    @Test func disablingDuringFetchDoesNotSendOrCommit() async {
        let fixture = Fixture()
        fixture.onFetch = {
            fixture.configuration = nil
            fixture.push.cancel()
        }
        await fixture.notify()?.value
        #expect(fixture.events == ["fetch", "complete"])
    }

    @MainActor
    private final class Fixture {
        private let metric = HealthMetric(rawValue: "stepCount")!
        var configuration: BackgroundPush.Configuration?
        var events: [String] = []
        var hasSamples = true
        var shouldFail = false
        var onFetch: (() -> Void)?

        init() {
            configuration = .init(metrics: [metric], endpoint: "https://example.test/health",
                                  authorizationHeader: "", includeUUID: true)
        }

        lazy var push = BackgroundPush(
            configuration: { [unowned self] in configuration },
            fetch: { [unowned self] metrics in
                #expect(metrics == [metric])
                events.append("fetch")
                onFetch?()
                let now = Date(timeIntervalSince1970: 1_700_000_000)
                let sample = HealthSample(type: metric.rawValue, category: metric.category.rawValue, value: 42,
                                          stringValue: nil, unit: "count", start: now, end: now,
                                          source: "Test", uuid: "test-sample")
                return .init(samples: hasSamples ? [sample] : [],
                             pendingAnchors: [.init(metric: metric, anchorData: Data([7]))],
                             isIncremental: true, skippedMetrics: [])
            },
            sender: { [unowned self] _ in
                FakeSender { data in
                    #expect(String(decoding: data, as: UTF8.self).contains("test-sample"))
                    self.events.append("send")
                    if self.shouldFail { throw TestError.rejected }
                }
            },
            commit: { [unowned self] outcome in
                #expect(outcome.pendingAnchors.map(\.anchorData) == [Data([7])])
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
    @Test func backgroundSenderUsesSharedNoRedirectSession() {
        let config = BackgroundPush.Configuration(metrics: [], endpoint: "https://a.example/hook",
                                                  authorizationHeader: "Bearer t", includeUUID: false)
        let first = BackgroundDelivery.makeSender(config)
        let second = BackgroundDelivery.makeSender(config)
        #expect(first.session === HTTPSender.backgroundSession)
        #expect(second.session === first.session, "每次推送都复用同一个会话")
        #expect(first.endpoint == config.endpoint)
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
        settings.endpoint = "https://a.example/hook"
        #expect(delivery.currentConfiguration()?.endpoint == "https://a.example/hook")
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

    private nonisolated struct FakeSender: ExportSender {
        let operation: @MainActor @Sendable (Data) throws -> Void

        func send(_ data: Data) async throws {
            try await operation(data)
        }
    }

    private enum TestError: Error { case rejected }
}
