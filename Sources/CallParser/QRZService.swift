/// The QRZ operations needed by a session.
protocol QRZService: Sendable {
  func requestSessionKey(userId: String, password: String) async throws -> String
  func requestQRZInformation(call: String, sessionKey: String) async throws -> String
}
