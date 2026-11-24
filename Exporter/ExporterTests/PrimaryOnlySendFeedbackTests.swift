import Foundation
import Testing
@testable import Exporter

@MainActor
struct PrimaryOnlySendFeedbackTests {
    @Test(arguments: [false, true])
    func interruptedPostShowsUnconfirmedWithoutRetryOrReplacingLastReceipt(saw201: Bool) async throws {
        let suite = "PrimaryOnlySendFeedbackTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        let endpoint = try #require(URL(string: "https://receiver.example.test/export"))
        settings.endpoint = endpoint.absoluteString
        let previous = SendReceipt(destination: .primary, host: "receiver.example.test")
            .dated(at: Date(timeIntervalSince1970: 100))
        settings.lastSendReceipt = previous
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        defer {
            try? FileManager.default.removeItem(at: file)
            defaults.removePersistentDomain(forName: suite)
        }
        let body = Data("{}".utf8)
        try body.write(to: file, options: .atomic)
        let response: HTTPURLResponse? = saw201 ? HTTPURLResponse(url: endpoint, statusCode: 201,
                                                                 httpVersion: nil, headerFields: nil) : nil
        let evidence = POSTAttemptSummary(metricsReports: [.init(transactions: [
            .init(fetchType: .networkLoad, completedConnection: true,
                  requestBodyBytes: Int64(body.count), response: response)
        ])])
        let probe = AttemptProbe(evidence: evidence)
        let sender = StubbedPrimarySender(sender: HTTPSender(endpoint: settings.endpoint, authorizationHeader: nil),
                                          probe: probe)
        let model = ExportModel(settings: settings, health: HealthKitManager(), manualSender: sender)
        model.exportFileURL = file
        model.showPreview = true

        await model.send()

        let requests = await probe.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url == endpoint)
        #expect(requests.first?.httpMethod == "POST")
        #expect(requests.first?.httpBody == body)
        #expect(model.manualSendOutcome?.result == .deliveryUnconfirmed)
        #expect(model.errorMessage == (saw201 ? SenderError.interruptedSuccessResponse(201).localizedDescription
                                           : SenderError.unconfirmedDelivery.localizedDescription))
        #expect(AppSettings(defaults: defaults).lastSendReceipt == previous)
    }

    private nonisolated struct StubbedPrimarySender: ExportSender {
        let sender: HTTPSender
        let probe: AttemptProbe

        func send(_ data: Data) async throws -> SendReceipt {
            try await sender.send(data) { request, _ in await probe.interrupt(request) }
        }
    }

    private actor AttemptProbe {
        let evidence: POSTAttemptSummary
        private(set) var requests: [URLRequest] = []

        init(evidence: POSTAttemptSummary) { self.evidence = evidence }

        func interrupt(_ request: URLRequest) -> POSTOutcome {
            requests.append(request)
            return .failure(URLError(.networkConnectionLost), evidence)
        }
    }
}
