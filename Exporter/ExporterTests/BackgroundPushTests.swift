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

    private nonisolated struct FakeSender: ExportSender {
        let operation: @MainActor @Sendable (Data) throws -> Void

        func send(_ data: Data) async throws {
            try await operation(data)
        }
    }

    private enum TestError: Error { case rejected }
}
