import Foundation
import Observation
import Testing
@testable import Exporter

@MainActor
struct EndpointSettingsTests {
    @MainActor
    private final class ObservationProbe {
        var changed = false
    }

    @Test func draftIsLocalUntilAppliedAndReloadsAsOneConfiguration() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let saved = AppSettings.EndpointDraft(endpoint: "https://old.test/hook", backupEndpoint: "",
                                                  authorizationHeader: "Bearer old-test-value")
            #expect(settings.applyEndpointDraft(saved))

            let observation = ObservationProbe()
            withObservationTracking {
                _ = settings.endpoint
                _ = settings.backupEndpoint
                _ = settings.authorizationHeader
            } onChange: {
                MainActor.assumeIsolated { observation.changed = true }
            }

            do {
                var cancelled = settings.endpointDraft
                cancelled.endpoint = "https://discarded.test/hook"
                cancelled.backupEndpoint = "http://discarded.local/hook"
                cancelled.authorizationHeader = "Bearer discarded-test-value"
                #expect(cancelled.isValid)
            }
            #expect(!observation.changed)
            #expect(settings.endpointDraft == saved)
            #expect(AppSettings(defaults: defaults).endpointDraft == saved)

            var next = settings.endpointDraft
            next.endpoint = " https://new.test/hook\n"
            next.backupEndpoint = " http://nas.local/hook "
            next.authorizationHeader = " Bearer new-test-value "
            #expect(settings.applyEndpointDraft(next))
            #expect(observation.changed)
            #expect(settings.endpoint == next.endpoint)
            #expect(settings.backupEndpoint == next.backupEndpoint)
            #expect(settings.authorizationHeader == next.authorizationHeader)
            #expect(AppSettings(defaults: defaults).endpointDraft == next)
        }
    }

    @Test func rejectsInvalidAddressesWithoutSavingAnyField() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let saved = AppSettings.EndpointDraft(endpoint: "https://saved.test/hook", backupEndpoint: "",
                                                  authorizationHeader: "Bearer saved-test-value")
            #expect(settings.applyEndpointDraft(saved))

            for (primary, backup) in [("http://primary.test/hook", ""),
                                      ("https://primary.test/hook", "http://public.test/hook"),
                                      (" \n", "https://backup.test/hook")] {
                let invalid = AppSettings.EndpointDraft(endpoint: primary, backupEndpoint: backup,
                                                        authorizationHeader: "Bearer unsaved-test-value")
                #expect(!settings.applyEndpointDraft(invalid))
                #expect(settings.endpointDraft == saved)
                #expect(AppSettings(defaults: defaults).endpointDraft == saved)
            }

            let localOnly = AppSettings.EndpointDraft(endpoint: " \n", backupEndpoint: "", authorizationHeader: "")
            #expect(settings.applyEndpointDraft(localOnly))
            #expect(!settings.hasEndpoint)
            #expect(AppSettings(defaults: defaults).endpointDraft == localOnly)
        }
    }

    @Test func backgroundPushUsesOnlyTheSavedConfigurationAndCanAlwaysBeDisabled() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.setBackgroundPushEnabled(true, with: settings.endpointDraft)
            #expect(!settings.backgroundPushEnabled)

            let saved = AppSettings.EndpointDraft(endpoint: "https://saved.test/hook", backupEndpoint: "",
                                                  authorizationHeader: "")
            #expect(settings.applyEndpointDraft(saved))
            settings.setBackgroundPushEnabled(true, with: saved)
            #expect(settings.backgroundPushEnabled)

            var invalid = saved
            invalid.endpoint = "http://invalid.test/hook"
            settings.setBackgroundPushEnabled(false, with: invalid)
            #expect(!AppSettings(defaults: defaults).backgroundPushEnabled)
            settings.setBackgroundPushEnabled(true, with: invalid)
            #expect(!settings.backgroundPushEnabled)
            #expect(settings.endpointDraft == saved)

            var edited = saved
            edited.authorizationHeader = "Bearer new-test-value"
            settings.setBackgroundPushEnabled(true, with: edited)
            #expect(!settings.backgroundPushEnabled)
            #expect(settings.applyEndpointDraft(edited))
            #expect(!settings.backgroundPushEnabled)
            settings.setBackgroundPushEnabled(true, with: edited)
            #expect(AppSettings(defaults: defaults).backgroundPushEnabled)
        }
    }

    @Test func migratesLegacyValuesWithoutNormalizingOrRetainingTheOldHeader() throws {
        try withDefaults { defaults in
            defaults.set(" https://primary.test/hook ", forKey: "settings.endpoint")
            defaults.set(" http://nas.local/hook ", forKey: "settings.backupEndpoint")
            defaults.set(" Bearer legacy-test-value ", forKey: "settings.authHeader")
            defaults.set(true, forKey: "settings.backgroundPushEnabled")

            let settings = AppSettings(defaults: defaults)
            #expect(settings.endpoint == " https://primary.test/hook ")
            #expect(settings.backupEndpoint == " http://nas.local/hook ")
            #expect(settings.authorizationHeader == " Bearer legacy-test-value ")
            #expect(settings.backgroundPushEnabled)
            #expect(defaults.object(forKey: "settings.authHeader") == nil)
            #expect(AppSettings(defaults: defaults).endpointDraft == settings.endpointDraft)

            settings.backupEndpoint = "https://new-backup.test/hook"
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.endpoint == settings.endpoint)
            #expect(reloaded.backupEndpoint == settings.backupEndpoint)
            #expect(reloaded.authorizationHeader == settings.authorizationHeader)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "EndpointSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
