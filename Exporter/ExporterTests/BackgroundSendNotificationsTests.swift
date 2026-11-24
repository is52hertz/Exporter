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

    @Test func failuresOnlyAfterTwoUnconfirmedBatchesAndOnlyOnceUntilSuccess() async {
        let fixture = Fixture()
        fixture.settings.backgroundNotificationMode = .failures
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.isEmpty)
        await fixture.notifications.report(.notConfirmed)
        await fixture.notifications.report(.notConfirmed)
        #expect(fixture.requests.map(\.identifier) == [BackgroundSendNotifications.failureIdentifier])
        #expect(fixture.requests.first?.content.interruptionLevel == .active)
        #expect(fixture.requests.first?.content.sound != nil)
        #expect(fixture.requests.first?.content.userInfo.isEmpty == true)
        await fixture.notifications.report(.success(sampleCount: 3, destination: .primary))
        #expect(fixture.removedNotices == [BackgroundSendNotifications.failureIdentifier])
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
        #expect(request.content.userInfo.isEmpty)
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
        #expect(fixture.removedNotices == [BackgroundSendNotifications.failureIdentifier, BackgroundSendNotifications.successIdentifier])
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
        var whileScheduling: (() -> Void)?

        lazy var notifications = BackgroundSendNotifications(settings: settings, authorization: { [unowned self] in
            authorizationChecks += 1
            beforeAuthorizationReturns?()
            return authorization
        }, schedule: { [unowned self] request in
            if failScheduling { throw CocoaError(.fileWriteUnknown) }
            requests.append(request)
            whileScheduling?()
        }, removeNotice: { [unowned self] identifier in removedNotices.append(identifier) })

        init(defaults: UserDefaults? = nil) {
            self.defaults = defaults ?? UserDefaults(suiteName: "BackgroundSendNotificationsTests.\(UUID())")!
            settings = AppSettings(defaults: self.defaults)
            settings.backgroundPushEnabled = true
        }
    }
}
