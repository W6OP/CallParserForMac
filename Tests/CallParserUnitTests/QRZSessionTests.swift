import Foundation
import Testing
@testable import CallParser

private actor MockQRZService: QRZService {
    var sessionResponses: [String]
    var lookupResponses: [String]
    var lookupKeys: [String] = []
    var loginCount = 0

    init(sessionResponses: [String], lookupResponses: [String] = []) {
        self.sessionResponses = sessionResponses
        self.lookupResponses = lookupResponses
    }

    func requestSessionKey(userId: String, password: String) async throws -> String {
        loginCount += 1
        guard !sessionResponses.isEmpty else { throw MockError.unexpectedRequest }
        return sessionResponses.removeFirst()
    }

    func requestQRZInformation(call: String, sessionKey: String) async throws -> String {
        lookupKeys.append(sessionKey)
        guard !lookupResponses.isEmpty else { throw MockError.unexpectedRequest }
        return lookupResponses.removeFirst()
    }

    enum MockError: Error { case unexpectedRequest }
}

struct QRZSessionTests {
    private func xml(_ content: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8" ?>
        <QRZDatabase version="1.36" xmlns="http://xmldata.qrz.com">
        \(content)
        </QRZDatabase>
        """
    }

    private func loginResponse(_ key: String) -> String {
        xml("""
        <Session>
        <Key>\(key)</Key>
        </Session>
        """)
    }

    private func successResponse(key: String = "test-key") -> String {
        xml("""
        <Callsign>
        <call>W1ABC</call>
        <country>United States</country>
        <lat>42.0</lat>
        <lon>-71.0</lon>
        <grid>FN42</grid>
        <geoloc>user</geoloc>
        </Callsign>
        <Session>
        <Key>\(key)</Key>
        </Session>
        """)
    }

    @Test func successfulLookupPreservesPreciseCoordinates() async throws {
        let service = MockQRZService(
            sessionResponses: [loginResponse("test-key")], lookupResponses: [successResponse()]
        )
        let session = QRZSession(qrzManager: service)
        #expect(try await session.logon(userId: "test-user", password: "test-password"))
        let result = try #require(await session.fetchCallSignData(call: "W1ABC", verboseLogging: false))
        #expect(result["call"] == "W1ABC")
        #expect(result["lat"] == "42.0")
        #expect(result["lon"] == "-71.0")
        #expect(await service.lookupKeys == ["test-key"])
    }

    @Test func expiredSessionRenewsAndRetries() async throws {
        let expired = xml("""
        <Session>
        <Error>Session Timeout</Error>
        </Session>
        """)
        let service = MockQRZService(
            sessionResponses: [loginResponse("first-key"), loginResponse("second-key")],
            lookupResponses: [expired, successResponse(key: "second-key")]
        )
        let session = QRZSession(qrzManager: service, sessionKeyRequestInterval: 0)
        #expect(try await session.logon(userId: "test-user", password: "test-password"))
        let result = await session.fetchCallSignData(call: "W1ABC", verboseLogging: false)
        #expect(result?["call"] == "W1ABC")
        #expect(await service.lookupKeys == ["first-key", "second-key"])
        #expect(await service.loginCount == 2)
    }

    @Test func notFoundReturnsNilWithoutRenewal() async throws {
        let missing = xml("""
        <Session>
        <Error>Not found: W1XYZ</Error>
        <Key>test-key</Key>
        </Session>
        """)
        let service = MockQRZService(sessionResponses: [loginResponse("test-key")], lookupResponses: [missing])
        let session = QRZSession(qrzManager: service)
        #expect(try await session.logon(userId: "test-user", password: "test-password"))
        #expect(await session.fetchCallSignData(call: "W1XYZ", verboseLogging: false) == nil)
        #expect(await service.loginCount == 1)
    }

    @Test func subscriptionLimitedResponseUsesGeocoding() async throws {
        let limited = xml("""
        <Callsign>
        <call>W1ABC</call>
        <addr2>Example City</addr2>
        <state>MA</state>
        <country>United States</country>
        </Callsign>
        <Session>
        <Key>test-key</Key>
        <Message>A subscription is required to access the complete record.</Message>
        </Session>
        """)
        let service = MockQRZService(sessionResponses: [loginResponse("test-key")], lookupResponses: [limited])
        let geo = GeoManager(gate: GeocodeRequestGate(), geocode: { _ in (42, -71) })
        let session = QRZSession(qrzManager: service, geoManager: geo)
        #expect(try await session.logon(userId: "test-user", password: "test-password"))
        let result = try #require(await session.fetchCallSignData(call: "W1ABC", verboseLogging: false))
        #expect(result["lat"] == "42.0")
        #expect(result["lon"] == "-71.0")
    }

    @Test(arguments: [
        "Username/password incorrect", "Password incorrect", "Connection refused",
        "Not found: W1XYZ", "Too many requests", "Unexpected service message"
    ])
    func lookupErrorsReturnNil(message: String) async throws {
        let response = xml("""
        <Session>
        <Error>\(message)</Error>
        <Key>test-key</Key>
        </Session>
        """)
        let service = MockQRZService(sessionResponses: [loginResponse("test-key")], lookupResponses: [response])
        let session = QRZSession(qrzManager: service)
        #expect(try await session.logon(userId: "test-user", password: "test-password"))
        #expect(await session.fetchCallSignData(call: "W1XYZ", verboseLogging: false) == nil)
    }

    @Test func rejectsZeroCoordinatesAndMissingCall() async throws {
        let zeroCoordinates = xml("""
        <call>W1ABC</call>
        <lat>0.0</lat>
        <lon>-71.0</lon>
        <Key>test-key</Key>
        """)
        let noCall = xml("""
        <lat>42.0</lat>
        <lon>-71.0</lon>
        <Key>test-key</Key>
        """)
        let service = MockQRZService(
            sessionResponses: [loginResponse("test-key")], lookupResponses: [zeroCoordinates, noCall]
        )
        let session = QRZSession(qrzManager: service)
        #expect(try await session.logon(userId: "test-user", password: "test-password"))
        #expect(await session.fetchCallSignData(call: "W1ABC", verboseLogging: false) == nil)
        #expect(await session.fetchCallSignData(call: "W1ABC", verboseLogging: false) == nil)
    }

    @Test(arguments: [
        ("Session Timeout", "timeout"),
        ("Username/password incorrect", "credentials"),
        ("Password incorrect", "credentials"),
        ("Connection refused", "lockout"),
        ("Not found: W1XYZ", "notFound"),
        ("Too many requests", "rate"),
        ("Unexpected service message", "other")
    ])
    func loginErrorsAreClassified(message: String, expected: String) async {
        let response = xml("""
        <Session>
        <Error>\(message)</Error>
        </Session>
        """)
        let service = MockQRZService(sessionResponses: [response])
        let session = QRZSession(qrzManager: service)
        do {
            _ = try await session.logon(userId: "test-user", password: "test-password")
            Issue.record("Expected login to fail")
        } catch let error as QRZManagerError {
            switch (expected, error) {
            case ("timeout", .sessionTimeout), ("credentials", .invalidCredentials),
                 ("lockout", .lockout), ("notFound", .notFound), ("rate", .requestTooFrequent):
                break
            case ("other", .qrzResponse(let returned)):
                #expect(returned == message)
            default:
                Issue.record("Unexpected error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
