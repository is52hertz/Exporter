import Foundation
import Testing
@testable import Exporter

@MainActor
struct ManualSendFeedbackTests {
    @Test(arguments: [SendReceipt.Destination.primary, .backup])
    func confirmedSendPublishesAndPersistsDatedReceipt(destination: SendReceipt.Destination) async throws {
        let undated = SendReceipt(destination: destination, host: "receiver.example.test")
        let fixture = try Fixture(sender: StubSender { data in
            #expect(data == Data("{}".utf8))
            return undated
        })
        defer { fixture.cleanUp() }
        let previousSync = Date(timeIntervalSince1970: 123)
        fixture.model.settings.lastSyncDate = previousSync
        let startedAt = Date()

        await fixture.model.send()

        let outcome = try #require(fixture.model.manualSendOutcome)
        let receipt = try #require(fixture.model.settings.lastSendReceipt)
        let confirmation = try #require(receipt.confirmedAt)
        #expect(startedAt <= confirmation && confirmation <= Date())
        #expect(receipt == undated.dated(at: confirmation))
        #expect(outcome.result == .success(sampleCount: 3, destination: destination))
        #expect(AppSettings(defaults: fixture.defaults).lastSendReceipt == receipt)
        #expect(fixture.model.settings.lastSyncDate == previousSync)
        #expect(fixture.model.errorMessage == nil)
        #expect(!fixture.model.isSending)
    }

    @Test func retryClearsOldFeedbackRejectsDuplicateAndDoesNotOverwriteReceiptOnUnconfirmedDelivery() async throws {
        let sender = RetrySender()
        let fixture = try Fixture(sender: StubSender { _ in try await sender.respond() })
        defer { fixture.cleanUp() }
        let model = fixture.model
        sender.model = model

        await model.send()
        let first = try #require(model.manualSendOutcome)
        let receipt = try #require(model.settings.lastSendReceipt)
        await model.send()

        let uncertain = try #require(model.manualSendOutcome)
        #expect(sender.attempts == 2)
        #expect(uncertain.result == .deliveryUnconfirmed)
        #expect(uncertain.id != first.id)
        #expect(model.settings.lastSendReceipt == receipt)
        #expect(model.errorMessage == SenderError.unconfirmedDelivery.localizedDescription)
        #expect(!model.isSending)
        #expect(!model.isWorking)
        model.errorMessage = nil // Dismiss the alert; the strip remains.
        #expect(model.manualSendOutcome?.id == uncertain.id)

        await model.send()
        let next = try #require(model.manualSendOutcome)
        #expect(sender.attempts == 3)
        #expect(next.result == first.result)
        #expect(next.id != first.id && next.id != uncertain.id)
        #expect(model.errorMessage == nil)
    }

    @Test func legacyAndBackgroundReceiptsDoNotPopulatePreviewAndNewArtifactClearsManualSuccess() async throws {
        let primary = SendReceipt(destination: .primary, host: "primary.example.test")
        let fixture = try Fixture(sender: StubSender { _ in primary }, legacyReceipt: Data(
            #"{"destination":"backup","host":"old.example.test"}"#.utf8
        ))
        defer { fixture.cleanUp() }
        let model = fixture.model
        #expect(model.settings.lastSendReceipt == SendReceipt(destination: .backup, host: "old.example.test"))
        #expect(model.settings.lastSendReceipt?.confirmedAt == nil)
        #expect(model.manualSendOutcome == nil)

        let background = SendReceipt(destination: .backup, host: "background.example.test").dated(at: Date())
        model.settings.lastSendReceipt = background
        #expect(model.manualSendOutcome == nil)

        await model.send()
        let receipt = try #require(model.settings.lastSendReceipt)
        #expect(model.manualSendOutcome?.result == .success(sampleCount: 3, destination: .primary))
        model.exportFileURL = fixture.fileURL.deletingLastPathComponent().appendingPathComponent("new.json")
        #expect(model.manualSendOutcome == nil)
        #expect(model.settings.lastSendReceipt == receipt)
    }

    @Test(arguments: [false, true])
    func failureStripUsesTransportClassificationWithoutChangingAlert(interruptedSuccess: Bool) async throws {
        let error: SenderError = interruptedSuccess
            ? .interruptedSuccessResponse(200)
            : .httpStatus(500, body: nil)
        let fixture = try Fixture(sender: StubSender { _ in throw error })
        defer { fixture.cleanUp() }

        await fixture.model.send()

        let outcome = try #require(fixture.model.manualSendOutcome)
        #expect(outcome.result == (interruptedSuccess ? .deliveryUnconfirmed : .failure))
        #expect(fixture.model.errorMessage == error.localizedDescription)
        #expect(fixture.model.settings.lastSendReceipt == nil)
        fixture.model.errorMessage = nil
        #expect(fixture.model.manualSendOutcome?.id == outcome.id)
    }

    @Test func cancelledSendProducesNoOutcomeOrAlert() async throws {
        let fixture = try Fixture(sender: StubSender { _ in throw CancellationError() })
        defer { fixture.cleanUp() }

        await fixture.model.send()

        #expect(fixture.model.manualSendOutcome == nil)
        #expect(fixture.model.settings.lastSendReceipt == nil)
        #expect(fixture.model.errorMessage == nil)
        #expect(!fixture.model.isSending)
    }

    @Test(arguments: [false, true])
    func closingPreviewWhileSendingSuppressesOutcomeAndAlertButPreservesConfirmedReceipt(confirmed: Bool) async throws {
        let sender = ClosingSender()
        let fixture = try Fixture(sender: StubSender { _ in try await sender.respond(confirmed: confirmed) })
        defer { fixture.cleanUp() }
        sender.model = fixture.model

        await fixture.model.send()

        #expect(!fixture.model.showPreview)
        #expect(fixture.model.manualSendOutcome == nil)
        #expect(fixture.model.errorMessage == nil)
        #expect((fixture.model.settings.lastSendReceipt?.confirmedAt != nil) == confirmed)
        fixture.model.showPreview = true
        #expect(fixture.model.manualSendOutcome == nil)
    }

    @MainActor
    private final class ClosingSender {
        weak var model: ExportModel?

        func respond(confirmed: Bool) throws -> SendReceipt {
            let model = try #require(self.model)
            #expect(model.isSending)
            model.showPreview = false
            guard confirmed else { throw SenderError.unconfirmedDelivery }
            return SendReceipt(destination: .primary, host: "receiver.example.test")
        }
    }

    private nonisolated struct StubSender: ExportSender {
        let respond: @Sendable (Data) async throws -> SendReceipt

        func send(_ data: Data) async throws -> SendReceipt {
            try await respond(data)
        }
    }

    @MainActor
    private final class RetrySender {
        weak var model: ExportModel?
        private(set) var attempts = 0

        func respond() async throws -> SendReceipt {
            attempts += 1
            if attempts == 2 {
                let model = try #require(self.model)
                #expect(model.isSending)
                #expect(model.manualSendOutcome == nil)
                await model.send() // Simulates a second tap while the transport is awaiting confirmation.
                throw SenderError.unconfirmedDelivery
            }
            return SendReceipt(destination: .primary, host: "receiver.example.test")
        }
    }

    @MainActor
    private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let fileURL: URL
        let model: ExportModel

        init(sender: any ExportSender, legacyReceipt: Data? = nil) throws {
            let suite = "ManualSendFeedbackTests-\(UUID())"
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
            let defaults = try #require(UserDefaults(suiteName: suite))
            try Data("{}".utf8).write(to: fileURL, options: .atomic)
            if let legacyReceipt {
                defaults.set(legacyReceipt, forKey: "settings.lastSendReceipt")
            }
            let settings = AppSettings(defaults: defaults)
            settings.endpoint = "https://receiver.example.test/health"
            let model = ExportModel(settings: settings, health: HealthKitManager(), manualSender: sender)
            model.exportFileURL = fileURL
            model.sampleCount = 3
            model.showPreview = true
            self.suite = suite
            self.defaults = defaults
            self.fileURL = fileURL
            self.model = model
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: fileURL)
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
