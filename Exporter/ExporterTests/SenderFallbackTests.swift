import CFNetwork
import Foundation
import Testing
import os
@testable import Exporter

@MainActor
struct SenderFallbackTests {
    @Test(arguments: [URLError.Code.timedOut, .cannotConnectToHost, .cannotFindHost,
                      .dnsLookupFailed, .serverCertificateUntrusted, .notConnectedToInternet])
    func provenPrimaryConnectionFailureSendsToBackupOnce(_ code: URLError.Code) async throws {
        let fixture = Fixture(primaryFailure: code, summary: Self.preHTTP)
        let receipt = try await fixture.send()
        #expect(receipt == SendReceipt(destination: .backup, host: "backup.test"))
        #expect(fixture.hosts == ["primary.test", "backup.test"])
        for call in fixture.calls {
            #expect(call.request.httpMethod == "POST")
            #expect(call.request.httpBody == Fixture.payload)
            #expect(call.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(call.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(call.session === fixture.sender.session, "Both HTTPS addresses use the original session")
        }
        #expect(fixture.calls.first?.request.timeoutInterval == 10)
        let backup = try #require(fixture.calls.last)
        let backupURL = try #require(backup.request.url)
        #expect(backup.request.timeoutInterval == URLRequest(url: backupURL).timeoutInterval)
    }

    @Test func primaryKeepsItsProxyAndHTTPBackupUsesSeparateDirectSession() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: 1,
                                            kCFNetworkProxiesHTTPProxy as String: "proxy.test"]
        let primarySession = URLSession(configuration: config)
        defer { primarySession.invalidateAndCancel() }
        let fixture = Fixture(backupEndpoint: "http://192.168.1.9/hook", session: primarySession,
                              primaryFailure: .timedOut, summary: Self.preHTTP)
        #expect(try await fixture.send() == SendReceipt(destination: .backup, host: "192.168.1.9"))
        let primary = try #require(fixture.calls.first)
        let backup = try #require(fixture.calls.last)
        #expect(primary.session === primarySession)
        #expect(primary.session.configuration.connectionProxyDictionary?[kCFNetworkProxiesHTTPEnable as String] as? Int == 1)
        #expect(backup.session === HTTPSender.directHTTPBackupSession)
        #expect(backup.session !== primary.session)
        for key in [kCFNetworkProxiesHTTPEnable as String, kCFNetworkProxiesProxyAutoConfigEnable as String,
                    "HTTPSEnable", "SOCKSEnable", "ProxyAutoDiscoveryEnable"] {
            #expect(backup.session.configuration.connectionProxyDictionary?[key] as? Int == 0)
        }
        #expect(backup.session.delegate is NoRedirectDelegate)
        #expect(backup.session.configuration.timeoutIntervalForRequest == HTTPSender.secureSession.configuration.timeoutIntervalForRequest)
        #expect(backup.session.configuration.timeoutIntervalForResource == HTTPSender.secureSession.configuration.timeoutIntervalForResource)
    }

    @Test func directHTTPBackupRetainsBackgroundSessionTimeouts() async throws {
        let fixture = Fixture(backupEndpoint: "http://mac-mini.local/hook", session: HTTPSender.backgroundSession,
                              primaryFailure: .cannotConnectToHost, summary: Self.preHTTP)
        _ = try await fixture.send()
        let primary = try #require(fixture.calls.first)
        let backup = try #require(fixture.calls.last)
        #expect(primary.session === HTTPSender.backgroundSession)
        #expect(primary.request.timeoutInterval == 10)
        #expect(backup.session === HTTPSender.directHTTPBackgroundBackupSession)
        #expect(backup.session.configuration.connectionProxyDictionary?[kCFNetworkProxiesHTTPEnable as String] as? Int == 0)
        #expect(backup.session.configuration.connectionProxyDictionary?[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Int == 0)
        #expect(backup.session.configuration.timeoutIntervalForRequest == 15)
        #expect(backup.session.configuration.timeoutIntervalForResource == 20)
        #expect(backup.session.delegate is NoRedirectDelegate)
    }

    @Test func triesPrimaryFirstAgainAfterBackupSuccess() async throws {
        let fixture = Fixture(primaryFailure: .cannotConnectToHost, summary: Self.preHTTP)
        #expect(try await fixture.send() == SendReceipt(destination: .backup, host: "backup.test"))
        let receipt = try await fixture.sender.send(Fixture.payload) { request, session in
            fixture.record(request, session)
            return Fixture.response(204, request: request)
        }
        #expect(receipt == SendReceipt(destination: .primary, host: "primary.test"))
        #expect(fixture.hosts == ["primary.test", "backup.test", "primary.test"])
    }

    @Test(arguments: ["", " \n\t "])
    func noBackupPreservesProvenPreconnectErrorAndDefaultTimeout(_ backupEndpoint: String) async throws {
        let fixture = Fixture(backupEndpoint: backupEndpoint, primaryFailure: .timedOut, summary: Self.preHTTP)
        do {
            _ = try await fixture.send()
            Issue.record("Expected original URLSession error")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(fixture.hosts == ["primary.test"])
        let primary = try #require(fixture.calls.first)
        let url = try #require(primary.request.url)
        #expect(primary.session === fixture.sender.session)
        #expect(primary.request.timeoutInterval == URLRequest(url: url).timeoutInterval)
    }

    @Test func invalidBackupIsRejectedBeforeAnyNetworking() async {
        let fixture = Fixture(backupEndpoint: "http://public.example/hook")
        do {
            _ = try await fixture.send()
            Issue.record("An invalid nonempty backup must fail even if primary would succeed")
        } catch SenderError.invalidBackupEndpoint {
            #expect(fixture.calls.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost, .cancelled, .cannotConnectToHost,
                      .dnsLookupFailed, .serverCertificateUntrusted],
          ["", "https://backup.test/hook"])
    func missingMetricsFailsClosed(_ code: URLError.Code, backupEndpoint: String) async {
        let fixture = Fixture(backupEndpoint: backupEndpoint, primaryFailure: code)
        await expectUnconfirmed(fixture)
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost], ["", "https://backup.test/hook"])
    func requestHeadersAloneMakeDeliveryUnconfirmed(_ code: URLError.Code, backupEndpoint: String) async {
        let tx = POSTAttemptSummary.Transaction(fetchType: .networkLoad, requestHeaderBytes: 17)
        await expectUnconfirmed(Fixture(backupEndpoint: backupEndpoint, primaryFailure: code, summary: Self.metrics([tx])))
    }

    @Test func allTransactionsMayProveFreshIncompleteNetworkLoads() async throws {
        let fixture = Fixture(primaryFailure: .timedOut, summary: Self.metrics([Self.preconnect, Self.preconnect]))
        #expect(try await fixture.send() == SendReceipt(destination: .backup, host: "backup.test"))
        #expect(fixture.hosts == ["primary.test", "backup.test"])
    }

    @Test func everyTransactionMustBeAFreshIncompleteNetworkLoad() async {
        for tx in [POSTAttemptSummary.Transaction(fetchType: .unknown), .init(fetchType: .localCache),
                   .init(fetchType: .networkLoad, reusedConnection: true),
                   .init(fetchType: .networkLoad, completedConnection: true), .init(fetchType: .networkLoad, httpTiming: true),
                   .init(fetchType: .networkLoad, responseHeaderBytes: 24), .init(fetchType: .networkLoad, requestBodyBytes: 1),
                   .init(fetchType: .networkLoad, responseBodyBytes: 1)] {
            for transactions in [[Self.preconnect, tx], [tx, Self.preconnect]] {
                await expectUnconfirmed(Fixture(primaryFailure: .timedOut, summary: Self.metrics(transactions)))
            }
        }
    }

    @Test func emptyOrDuplicateMetricsReportsFailClosed() async {
        let clean = POSTAttemptSummary.MetricsReport(transactions: [Self.preconnect])
        let empty = POSTAttemptSummary.MetricsReport(transactions: [])
        for reports in [[empty], [clean, clean], [clean, empty], [empty, clean]] {
            await expectUnconfirmed(Fixture(primaryFailure: .timedOut, summary: .init(metricsReports: reports)))
        }
    }

    @Test func taskWideObservationsBlockFallbackDespiteCleanTransactions() async {
        let reports = Self.preHTTP.metricsReports
        let summaries: [POSTAttemptSummary] = [
            .init(metricsReports: reports, receivedResponseCallback: true),
            .init(metricsReports: reports, sentBodyProgress: true),
            .init(metricsReports: reports, taskHadResponse: true),
            .init(metricsReports: reports, taskBytesSent: 1),
            .init(metricsReports: reports, taskBytesReceived: 1),
            .init(metricsReports: [.init(transactions: [Self.preconnect], redirectCount: 1)])
        ]
        for summary in summaries {
            await expectUnconfirmed(Fixture(primaryFailure: .timedOut, summary: summary))
        }
    }

    @Test(arguments: [100, 401, 503])
    func earlierHTTPResponseIsNeverReportedAsFinalStatus(_ status: Int) async throws {
        let earlier = try Self.transaction(responseStatus: status)
        await expectUnconfirmed(Fixture(primaryFailure: .timedOut, summary: Self.metrics([earlier, Self.preconnect])))
    }

    @Test func authenticationChallengeThenStartedTransactionWithoutResponseIsUnconfirmed() async throws {
        let challenge = try Self.transaction(responseStatus: 401)
        let started = POSTAttemptSummary.Transaction(fetchType: .networkLoad, httpTiming: true, requestHeaderBytes: 31)
        var summary = Self.metrics([challenge, started])
        // The task-wide response can still refer to the authentication challenge, not the final transaction.
        summary.taskHadResponse = true
        await expectUnconfirmed(Fixture(primaryFailure: .timedOut, summary: summary))
    }

    @Test func informationalResponseInFinalTransactionCannotSurfaceAnEarlierFinalStatus() async throws {
        let earlier = try Self.transaction(responseStatus: 401)
        let final = try Self.transaction(responseStatus: 103)
        await expectUnconfirmed(Fixture(primaryFailure: .timedOut, summary: Self.metrics([earlier, final])))
    }

    @Test func duplicateMetricsCannotIdentifyFinalHTTPStatus() async throws {
        let transactions = [try Self.transaction(responseStatus: 401)]
        let report = POSTAttemptSummary.MetricsReport(transactions: transactions)
        await expectUnconfirmed(Fixture(primaryFailure: .timedOut, summary: .init(metricsReports: [report, report])))
    }

    @Test func lostConnectionIsNotAConnectClassError() async {
        await expectUnconfirmed(Fixture(primaryFailure: .networkConnectionLost, summary: Self.preHTTP))
    }

    @Test(arguments: [302, 307, 400, 401, 500, 503])
    func anyPrimaryHTTPResponsePrecludesFallback(_ status: Int) async {
        let fixture = Fixture(primaryStatus: status)
        do {
            _ = try await fixture.send()
            Issue.record("An HTTP response outside 2xx must fail")
        } catch SenderError.httpStatus(let actual, _) {
            #expect(actual == status)
            #expect(fixture.hosts == ["primary.test"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: ["", "https://backup.test/hook"])
    func onlyFinalHTTPStatusIsHonoredEvenIfResponseBodyTimesOut(_ backupEndpoint: String) async throws {
        let earlier = try Self.transaction(responseStatus: 401)
        let final = try Self.transaction(responseStatus: 307)
        let fixture = Fixture(backupEndpoint: backupEndpoint, primaryFailure: .timedOut, summary: Self.metrics([earlier, final]))
        do {
            _ = try await fixture.send()
            Issue.record("Expected known HTTP status")
        } catch SenderError.httpStatus(let status, let body) {
            #expect(status == 307)
            #expect(body == nil)
            #expect(fixture.hosts == ["primary.test"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: ["", "https://backup.test/hook"])
    func successfulStatusWithInterruptedBodyReportsStatusWithoutReceiptOrRetry(_ backupEndpoint: String) async throws {
        var final = try Self.transaction(responseStatus: 201)
        final.responseBodyBytes = 1
        let fixture = Fixture(backupEndpoint: backupEndpoint, primaryFailure: .timedOut, summary: Self.metrics([final]))
        do {
            _ = try await fixture.send()
            Issue.record("An incomplete response must not produce a receipt")
        } catch SenderError.interruptedSuccessResponse(let status) {
            #expect(status == 201)
            #expect(fixture.hosts == ["primary.test"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func backupRedirectIsReportedAndNoOtherPostIsIssued() async {
        let fixture = Fixture(primaryFailure: .cannotConnectToHost, summary: Self.preHTTP, backupStatus: 307)
        do {
            _ = try await fixture.send()
            Issue.record("A redirect from backup must fail")
        } catch SenderError.httpStatus(let status, _) {
            #expect(status == 307)
            #expect(fixture.hosts == ["primary.test", "backup.test"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: ["https://backup.test/other", "https://unconfigured.test/steal", "http://backup.test/downgrade"])
    func taskDelegateRejectsAllRedirectTargets(_ target: String) throws {
        let source = try #require(URL(string: "https://backup.test/hook"))
        let destination = try #require(URL(string: target))
        let response = try #require(HTTPURLResponse(url: source, statusCode: 307, httpVersion: nil,
                                                      headerFields: ["Location": target]))
        let session = HTTPSender.secureSession
        let task = session.dataTask(with: source)
        defer { task.cancel() }
        let delegate = NoRedirectDelegate(recordsPostEvidence: true)
        var called = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: destination)) { request in
            called = true
            #expect(request == nil)
        }
        #expect(called)
    }

    @Test(arguments: ["", "https://backup.test/hook"])
    func revokedAuthorizationPreventsPrimaryAttempt(_ backupEndpoint: String) async {
        let authorization = POSTStartAuthorization()
        let fixture = Fixture(backupEndpoint: backupEndpoint, startAuthorization: authorization)
        authorization.invalidate()
        do {
            _ = try await fixture.send()
            Issue.record("Revoked settings must not start a primary POST")
        } catch is CancellationError {
            #expect(fixture.calls.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func revocationAfterPrimaryStartPreventsBackupAttempt() async {
        let authorization = POSTStartAuthorization()
        let fixture = Fixture(startAuthorization: authorization)
        let summary = Self.preHTTP
        do {
            _ = try await fixture.sender.send(Fixture.payload) { request, session in
                fixture.record(request, session)
                authorization.invalidate()
                return .failure(URLError(.timedOut), summary)
            }
            Issue.record("Revoked settings must not start a backup POST")
        } catch is CancellationError {
            #expect(fixture.hosts == ["primary.test"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func authorizedProductionTaskDeliversResponseBodyAndRevokedTaskCannotStart() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let authorization = POSTStartAuthorization()
        let sender = HTTPSender(endpoint: "https://transport.test/hook", authorizationHeader: nil,
                                session: session, startAuthorization: authorization)

        do {
            _ = try await sender.send(Fixture.payload)
            Issue.record("Expected the stub's error response")
        } catch SenderError.httpStatus(let status, let body) {
            #expect(status == 400)
            #expect(body == "stub response")
        }

        authorization.invalidate()
        do {
            _ = try await sender.send(Fixture.payload)
            Issue.record("The revoked task must not resume")
        } catch is CancellationError {
            // The same request would otherwise complete with the stub's HTTP status.
        }
    }

    @Test(arguments: ["", "https://backup.test/hook"])
    func cancellationAfterPossibleSendIsUnconfirmedAndDoesNotRetry(_ backupEndpoint: String) async {
        let fixture = Fixture(backupEndpoint: backupEndpoint)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await fixture.sender.send(Fixture.payload) { request, session in
                fixture.record(request, session)
                signal.yield(())
                try? await Task.sleep(for: .seconds(3600))
                return .failure(URLError(.cancelled), POSTAttemptSummary(sentBodyProgress: true))
            }
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected uncertain delivery, not a retry or a plain cancellation")
        } catch SenderError.unconfirmedDelivery {
            #expect(fixture.hosts == ["primary.test"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test(arguments: ["http://10.0.0.1", "http://172.16.0.1", "http://172.31.255.254",
                      "http://192.168.1.1:3000/hook", "http://169.254.1.1", "http://[fc00::1]",
                      "http://[fd12:3456::2]:8080/hook", "http://[fe80::1]", "http://[febf::1]",
                      " \n HTTP://Mac-Mini.LoCaL/push \t", "http://a.b.local", "http://mac.local.:3000/hooks",
                      "https://public.example/push", "https://8.8.8.8", "https://[2001:4860::8888]",
                      "https://xn--caf-dma.example", "https://café.example/hook"])
    func acceptedBackupAddresses(_ endpoint: String) {
        #expect(HTTPSender.validatedBackupURL(endpoint) != nil)
    }

    @Test(arguments: ["", "http://", "ftp://host.local", "//host.local", "http://local", "http://printer",
                      "http://example.com", "http://127.0.0.1", "http://8.8.8.8", "http://172.15.0.1",
                      "http://172.32.0.1", "http://169.253.0.1", "http://[fe7f::1]", "http://[fec0::1]",
                      "http://[::1]", "http://[::ffff:192.168.1.1]", "http://[fe80::1%25en0]",
                      "http://box..local", "http://box_local.local", "http://-box.local", "http://box-.local",
                      "http://box.local.evil.test", "http://box%2elocal", "http://box。local", "http://.local",
                      "https://user@host.local", "https://:secret@host.local", "https://@host.local",
                      "http://café.local", "https://user@café.example", "https://１９２.１６８.１.１",
                      "https://box.local\\@unconfigured.test", "https://box.local:65536", "https://box.local:",
                      "http://192.168.1.1%00", "http://192.168.01.1", "http://192.168.1", "http://3232235777",
                      "http://0xc0a80101", "https://0300.0250.1.1", "https://192.168.1.1."])
    func unsafeOrAmbiguousBackupAddressesAreRejected(_ endpoint: String) {
        #expect(HTTPSender.validatedBackupURL(endpoint) == nil)
    }

    private static let preconnect = POSTAttemptSummary.Transaction(fetchType: .networkLoad)
    private static let preHTTP = metrics([preconnect])

    private static func metrics(_ transactions: [POSTAttemptSummary.Transaction]) -> POSTAttemptSummary {
        .init(metricsReports: [.init(transactions: transactions)])
    }

    private static func transaction(responseStatus: Int) throws -> POSTAttemptSummary.Transaction {
        let url = try #require(URL(string: "https://primary.test/hook"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: responseStatus, httpVersion: nil, headerFields: nil))
        return .init(fetchType: .networkLoad, response: response)
    }

    private func expectUnconfirmed(_ fixture: Fixture) async {
        do {
            _ = try await fixture.send()
            Issue.record("Expected unconfirmed delivery after exactly one primary POST attempt")
        } catch SenderError.unconfirmedDelivery {
            #expect(fixture.hosts == ["primary.test"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private nonisolated final class TransportStub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "transport.test" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("stub response".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private nonisolated final class Fixture: Sendable {
        struct Call: Sendable {
            let request: URLRequest
            let session: URLSession
        }

        static let payload = Data("{}".utf8)
        let sender: HTTPSender
        private let callLog = OSAllocatedUnfairLock(initialState: [Call]())
        private let primaryFailure: URLError.Code?
        private let summary: POSTAttemptSummary
        private let primaryStatus: Int
        private let backupStatus: Int

        init(backupEndpoint: String = "https://backup.test/hook", session: URLSession = HTTPSender.secureSession,
             primaryFailure: URLError.Code? = nil, summary: POSTAttemptSummary = POSTAttemptSummary(),
             primaryStatus: Int = 204, backupStatus: Int = 204, startAuthorization: POSTStartAuthorization? = nil) {
            sender = HTTPSender(endpoint: "https://primary.test/hook", backupEndpoint: backupEndpoint,
                                authorizationHeader: " Bearer test-token ", session: session,
                                startAuthorization: startAuthorization)
            self.primaryFailure = primaryFailure
            self.summary = summary
            self.primaryStatus = primaryStatus
            self.backupStatus = backupStatus
        }

        var calls: [Call] { callLog.withLock { $0 } }
        var hosts: [String] { calls.compactMap { $0.request.url?.host } }

        func record(_ request: URLRequest, _ session: URLSession) {
            callLog.withLock { $0.append(Call(request: request, session: session)) }
        }

        func send() async throws -> SendReceipt {
            try await sender.send(Self.payload) { [self] request, session in
                record(request, session)
                if request.url?.host == "primary.test" {
                    if let primaryFailure { return .failure(URLError(primaryFailure), summary) }
                    return Self.response(primaryStatus, request: request)
                }
                return Self.response(backupStatus, request: request)
            }
        }

        static func response(_ status: Int, request: URLRequest) -> POSTOutcome {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
                return .failure(URLError(.badServerResponse), POSTAttemptSummary())
            }
            return .response(Data(), response)
        }
    }
}
