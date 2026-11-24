import Foundation
import Testing
import UserNotifications
@testable import Exporter

@MainActor
struct BackgroundSendNotificationsTests {
    @Test func freshAndPreviouslyInstalledDefaultsDoNotNotify() async {
        let fixture = Fixture()
        #expect(fixture.settings.backgroundNotificationMode == .off)
        await fixture.notifications.report(.notConfirmed)
        await fixture.notifications.report(.notConfirmed)
        await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
        #expect(fixture.authorizationChecks == 0)
        #expect(fixture.removedNotices == [BackgroundSendNotifications.failureIdentifier])
        #expect(fixture.requests.isEmpty)
    }

    @Test func failuresOnlyAfterTwoUnconfirmedBatchesAndOnlyOnceUntilSuccess() async throws {
        let fixture = Fixture()
        fixture.settings.backgroundNotificationMode = .failures
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.isEmpty)
        await fixture.notifications.report(.notConfirmed)
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.map(\.identifier) == [BackgroundSendNotifications.failureIdentifier])
        #expect(fixture.requests.first?.content.interruptionLevel == .active)
        #expect(fixture.requests.first?.content.sound != nil)
        #expect(fixture.requests.first?.content.userInfo.count == 1)
        #expect(fixture.requests.first.flatMap(fixture.revision).flatMap(UUID.init(uuidString:)) != nil)
        let failure = try #require(fixture.requests.first)
        await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
        #expect(fixture.removedNotices == [BackgroundSendNotifications.failureIdentifier])
        #expect(fixture.presentationOptions(for: failure).isEmpty)
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.count == 1)
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.count == 2)
    }

    @Test func failureStreakPersistsAcrossRelaunchAndResetsAfterAddressChange() async {
        let old = Fixture()
        old.settings.backgroundNotificationMode = .failures
        await old.notifications.report(.notConfirmed)
        let restored = Fixture(defaults: old.defaults)
        #expect(restored.settings.backgroundNotificationMode == .failures)
        await restored.notifications.report(.notConfirmed)
        #expect(restored.requests.count == 1)
        restored.settings.endpoint = "https://replacement.example.test/export"
        await restored.notifications.report(.notConfirmed)
        #expect(restored.requests.count == 1)
        await restored.notifications.report(.notConfirmed)
        #expect(restored.requests.count == 2)
    }

    @Test func optionalSuccessNoticesContainOnlyCountAndDestinationRole() async throws {
        let fixture = Fixture()
        fixture.settings.backgroundNotificationMode = .all
        fixture.settings.endpoint = "https://private.example.test"
        fixture.settings.authorizationHeader = "private-test-value"
        await fixture.notifications.report(.success(sampleCount: 42, destination: .backup))
        let request = try #require(fixture.requests.first)
        #expect(request.identifier == BackgroundSendNotifications.successIdentifier)
        #expect(request.trigger == nil)
        #expect(request.content.body.contains(42.formatted()))
        #expect(!request.content.body.contains("private"))
        #expect(request.content.userInfo.count == 1)
        #expect(fixture.revision(request).flatMap(UUID.init(uuidString:)) != nil)
        #expect(request.content.sound == nil)
        #expect(request.content.interruptionLevel == .passive)
        #expect(request.content.threadIdentifier == "exporter.push")
        await fixture.notifications.report(.success(sampleCount: 42, destination: .primary))
        #expect(fixture.requests.count == 2)
        #expect(fixture.requests.last?.content.body != request.content.body)
    }

    @Test func deniedPermissionDoesNotScheduleAndSchedulingCanRetryOnNextFailure() async {
        let fixture = Fixture()
        fixture.settings.backgroundNotificationMode = .failures
        fixture.authorization = .denied
        await fixture.notifications.report(.notConfirmed)
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.isEmpty)
        fixture.authorization = .allowed
        fixture.failScheduling = true
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.isEmpty)
        fixture.failScheduling = false
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.count == 1)
    }

    @Test func optOutOrDestinationChangeDuringPermissionLookupInvalidatesNotice() async {
        let fixture = Fixture()
        fixture.settings.backgroundNotificationMode = .all
        fixture.beforeAuthorizationReturns = {
            // Even toggling back on does not authorize this already obsolete result.
            fixture.settings.backgroundNotificationMode = .off
            fixture.settings.backgroundNotificationMode = .all
        }
        await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
        #expect(fixture.requests.isEmpty)
        fixture.beforeAuthorizationReturns = { fixture.settings.backgroundPushEnabled = false }
        await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
        #expect(fixture.requests.isEmpty)
        fixture.beforeAuthorizationReturns = nil
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.authorizationChecks == 2)
    }

    @Test func changingSuccessPreferenceWhileAddingFailureDoesNotRepeatTheAlert() async {
        let fixture = Fixture()
        fixture.settings.backgroundNotificationMode = .failures
        await fixture.notifications.report(.notConfirmed)
        fixture.whileScheduling = { fixture.settings.backgroundNotificationMode = .all }
        await fixture.notifications.report(.notConfirmed)
        fixture.whileScheduling = nil
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.map(\.identifier) == [BackgroundSendNotifications.failureIdentifier])
        #expect(fixture.removedNotices.isEmpty)
    }

    @Test func optingOutWhileAddingSuccessWithdrawsTheRequest() async {
        let fixture = Fixture()
        fixture.settings.backgroundNotificationMode = .all
        fixture.whileScheduling = { fixture.settings.backgroundNotificationMode = .failures }
        await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
        fixture.whileScheduling = nil
        #expect(fixture.requests.map(\.identifier) == [BackgroundSendNotifications.successIdentifier])
        #expect(fixture.removedNotices == [BackgroundSendNotifications.failureIdentifier,
                                           BackgroundSendNotifications.successIdentifier,
                                           BackgroundSendNotifications.successIdentifier])
        #expect(fixture.requests.allSatisfy { fixture.presentationOptions(for: $0).isEmpty })
    }

    @Test func settingsRevokeBothKindsAfterSchedulingHasReturned() async throws {
        for change in Revocation.allCases {
            let fixture = Fixture()
            fixture.settings.backgroundNotificationMode = .all
            await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
            await fixture.notifications.report(.notConfirmed)
            await fixture.notifications.report(.notConfirmed)
            let success = try #require(fixture.requests.first)
            let failure = try #require(fixture.requests.last)
            #expect(fixture.presentationOptions(for: success) == [.list])
            #expect(fixture.presentationOptions(for: failure) == [.banner, .list, .sound])
            fixture.removedNotices.removeAll()

            let restore = change.apply(to: fixture.settings)
            #expect(fixture.removedNotices == [success.identifier, failure.identifier], "\(change)")
            #expect(fixture.presentationOptions(for: success).isEmpty, "\(change)")
            #expect(fixture.presentationOptions(for: failure).isEmpty, "\(change)")

            // Simulate queued delegate callbacks even after the original settings are restored.
            restore()
            #expect(fixture.presentationOptions(for: success).isEmpty, "\(change)")
            #expect(fixture.presentationOptions(for: failure).isEmpty, "\(change)")
            await fixture.notifications.report(.notConfirmed)
            #expect(fixture.requests.count == 2, "\(change)")
            await fixture.notifications.report(.notConfirmed)
            let current = try #require(fixture.requests.last)
            #expect(fixture.requests.count == 3, "\(change)")
            #expect(fixture.presentationOptions(for: current) == [.banner, .list, .sound], "\(change)")
        }
    }

    @Test func successOptOutAfterSchedulingLeavesFailureCurrent() async throws {
        let fixture = Fixture()
        fixture.settings.backgroundNotificationMode = .all
        await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
        await fixture.notifications.report(.notConfirmed)
        await fixture.notifications.report(.notConfirmed)
        let success = try #require(fixture.requests.first)
        let failure = try #require(fixture.requests.last)
        fixture.removedNotices.removeAll()

        fixture.settings.backgroundNotificationMode = .failures
        #expect(fixture.presentationOptions(for: success).isEmpty)
        #expect(fixture.presentationOptions(for: failure) == [.banner, .list, .sound])
        fixture.settings.backgroundNotificationMode = .all
        #expect(fixture.removedNotices == [success.identifier])
        #expect(fixture.presentationOptions(for: success).isEmpty)
        #expect(fixture.presentationOptions(for: failure) == [.banner, .list, .sound])
        await fixture.notifications.report(.notConfirmed)
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.count == 2)
    }

    @Test func afterRelaunchOnlyCurrentRevisionCanPresent() async throws {
        let fixture = Fixture()
        fixture.settings.backgroundNotificationMode = .all
        await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
        let old = try #require(fixture.requests.first)
        fixture.settings.authorizationHeader = "replacement-auth"
        await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
        let current = try #require(fixture.requests.last)
        let restored = Fixture(defaults: fixture.defaults)
        #expect(restored.presentationOptions(for: old).isEmpty)
        #expect(restored.presentationOptions(for: current) == [.list])
        #expect(BackgroundSendNotifications.presentationOptions(for: current.identifier, revision: nil,
                                                                settings: restored.settings).isEmpty)
    }

    @Test func recoveryDuringFailureAddWithdrawsTheOldFailureAndKeepsNextStreakEligible() async throws {
        let fixture = Fixture()
        fixture.settings.backgroundNotificationMode = .failures
        await fixture.notifications.report(.notConfirmed)
        fixture.whileScheduling = { [unowned fixture] in
            await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
        }
        await fixture.notifications.report(.notConfirmed)
        fixture.whileScheduling = nil
        let old = try #require(fixture.requests.first)
        #expect(fixture.removedNotices == [old.identifier, old.identifier])
        #expect(fixture.presentationOptions(for: old).isEmpty)
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.count == 1)
        await fixture.notifications.report(.notConfirmed)
        let replacement = try #require(fixture.requests.last)
        #expect(fixture.requests.count == 2)
        #expect(fixture.presentationOptions(for: replacement) == [.banner, .list, .sound])
        #expect(fixture.presentationOptions(for: old).isEmpty)
    }

    @Test func obsoleteInFlightAddCannotRemoveTheReplacementWithTheSameIdentifier() async throws {
        let fixture = Fixture()
        fixture.settings.backgroundNotificationMode = .failures
        await fixture.notifications.report(.notConfirmed)
        let (started, signalStart) = AsyncStream<Void>.makeStream()
        let (release, signalRelease) = AsyncStream<Void>.makeStream()
        fixture.whileScheduling = {
            signalStart.yield(())
            for await _ in release { break }
        }
        let staleReport = Task { await fixture.notifications.report(.notConfirmed) }
        var startEvents = started.makeAsyncIterator()
        _ = await startEvents.next()
        fixture.whileScheduling = nil
        await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
        await fixture.notifications.report(.notConfirmed)

        let (authorized, signalAuthorization) = AsyncStream<Void>.makeStream()
        fixture.beforeAuthorizationReturns = { _ = signalAuthorization.yield(()) }
        let currentReport = Task { await fixture.notifications.report(.notConfirmed) }
        var authorizationEvents = authorized.makeAsyncIterator()
        _ = await authorizationEvents.next()
        #expect(fixture.requests.count == 1)
        signalRelease.yield(())
        await staleReport.value
        await currentReport.value

        let old = try #require(fixture.requests.first)
        let current = try #require(fixture.requests.last)
        #expect(fixture.requests.count == 2)
        #expect(fixture.removedNotices == [old.identifier, old.identifier])
        #expect(fixture.noticeEvents == ["add", "remove", "remove", "add"])
        #expect(fixture.presentationOptions(for: old).isEmpty)
        #expect(fixture.presentationOptions(for: current) == [.banner, .list, .sound])
    }

    private enum Revocation: CaseIterable {
        case push, master, primaryEndpoint, backupEndpoint, authorization, metrics, uuid

        @MainActor
        func apply(to settings: AppSettings) -> @MainActor () -> Void {
            let original = settings.endpointDraft
            switch self {
            case .push:
                settings.backgroundPushEnabled = false
                return { settings.backgroundPushEnabled = true }
            case .master:
                settings.backgroundNotificationMode = .off
                return { settings.backgroundNotificationMode = .all }
            case .primaryEndpoint, .backupEndpoint, .authorization:
                var draft = original
                switch self {
                case .primaryEndpoint: draft.endpoint = "https://replacement.example.test/export"
                case .backupEndpoint: draft.backupEndpoint = "http://192.168.1.7/export"
                case .authorization: draft.authorizationHeader = "replacement-auth"
                default: break
                }
                #expect(settings.applyEndpointDraft(draft))
                return { _ = settings.applyEndpointDraft(original) }
            case .metrics:
                let metrics = settings.selectedMetrics
                settings.selectedMetrics = []
                return { settings.selectedMetrics = metrics }
            case .uuid:
                settings.includeUUID.toggle()
                return { settings.includeUUID.toggle() }
            }
        }
    }

    @MainActor
    private final class Fixture {
        let defaults: UserDefaults
        let settings: AppSettings
        var authorization: BackgroundSendNotifications.Authorization = .allowed
        var authorizationChecks = 0
        var failScheduling = false
        var beforeAuthorizationReturns: (() -> Void)?
        var requests: [UNNotificationRequest] = []
        var removedNotices: [String] = []
        var noticeEvents: [String] = []
        var whileScheduling: (@MainActor () async -> Void)?

        lazy var notifications = BackgroundSendNotifications(settings: settings, authorization: { [unowned self] in
            authorizationChecks += 1
            beforeAuthorizationReturns?()
            return authorization
        }, schedule: { [unowned self] request in
            if failScheduling { throw CocoaError(.fileWriteUnknown) }
            requests.append(request)
            noticeEvents.append("add")
            await whileScheduling?()
        }, removeNotice: { [unowned self] identifier in
            removedNotices.append(identifier)
            noticeEvents.append("remove")
        })

        init(defaults: UserDefaults? = nil) {
            self.defaults = defaults ?? UserDefaults(suiteName: "BackgroundSendNotificationsTests.\(UUID())")!
            settings = AppSettings(defaults: self.defaults)
            if !settings.hasEndpoint { settings.endpoint = "https://original.example.test/export" }
            settings.backgroundPushEnabled = true
        }

        func presentationOptions(for request: UNNotificationRequest) -> UNNotificationPresentationOptions {
            BackgroundSendNotifications.presentationOptions(for: request.identifier, revision: revision(request), settings: settings)
        }

        func revision(_ request: UNNotificationRequest) -> String? {
            BackgroundSendNotifications.revision(in: request)
        }
    }
}
