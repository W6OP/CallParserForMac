//
//  QRZManager.swift
//  CallParser
//
//  Created by Peter Bourget on 7/8/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation
import os

// MARK: - QRZManager (Stateless Network Layer)

/// Handles raw HTTP requests to QRZ.com. All state (session key, credentials)
/// is passed in by the caller (QRZSession actor).
struct QRZManager: Sendable {

  private let logger = Logger(subsystem: "com.w6op.CallParser", category: "QRZManager")

  /// Shared session with an explicit request timeout so an unresponsive
  /// QRZ.com server surfaces a timeout in ~20s rather than hanging on the
  /// `URLSession.shared` 60s default. `waitsForConnectivity` lets a brief
  /// loss of connectivity recover instead of failing immediately, bounded by
  /// the resource timeout so it can never hang indefinitely.
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 60
    configuration.waitsForConnectivity = true
    return URLSession(configuration: configuration)
  }()

  /// Request a session key from QRZ.com.
  /// - Parameters:
  ///   - userId: QRZ.com username.
  ///   - password: QRZ.com password.
  /// - Returns: Raw XML response string (empty on a non-200 response).
  /// - Throws: `URLError` if the request fails at the network layer
  ///   (e.g. a timeout when QRZ.com is unreachable), so callers can
  ///   distinguish connectivity failures from QRZ API errors.
  func requestSessionKey(userId: String, password: String) async throws -> String {
    logger.info("Request Session Key")

    guard !userId.isEmpty && !password.isEmpty else {
      logger.info("Missing user name or password.")
      return ""
    }

    let urlParameters = "\(userId);password=\(password);agent=com.w6op.CallParser2.0"

    guard let url = URL(string: "https://xmldata.qrz.com/xml/current/?username=\(urlParameters)") else {
      logger.info("Invalid user name or password: \(userId)")
      return ""
    }

    let (data, response) = try await Self.session.data(from: url)

    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      print("The server responded with an error")
      return ""
    }

    guard let mime = response.mimeType, mime == "application/json" else {
      // QRZ returns XML, not JSON
      return String(decoding: data, as: UTF8.self)
    }

    return ""
  }

  /// Request call sign data from QRZ.com.
  /// - Parameters:
  ///   - call: The call sign to look up.
  ///   - sessionKey: A valid QRZ session key.
  /// - Returns: Raw XML response string (empty on failure).
  func requestQRZInformation(call: String, sessionKey: String) async throws -> String {
    URLCache.shared.removeAllCachedResponses()

    let urlParameters = "\(sessionKey);callsign=\(call)"
    guard let url = URL(string: "https://xmldata.qrz.com/xml/current/?s=\(urlParameters)")
    else { return "" }

    let (data, response) = try await Self.session.data(from: url)

    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      print("The server responded with an error")
      return ""
    }

    guard let mime = response.mimeType, mime == "application/json" else {
      return String(decoding: data, as: UTF8.self)
    }

    return ""
  }
}
