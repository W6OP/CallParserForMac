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

  /// Request a session key from QRZ.com.
  /// - Parameters:
  ///   - userId: QRZ.com username.
  ///   - password: QRZ.com password.
  /// - Returns: Raw XML response string (empty on failure).
  func requestSessionKey(userId: String, password: String) async -> String {
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

    do {
      let (data, response) = try await URLSession.shared.data(from: url)

      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        print("The server responded with an error")
        return ""
      }

      guard let mime = response.mimeType, mime == "application/json" else {
        // QRZ returns XML, not JSON
        return String(decoding: data, as: UTF8.self)
      }
    } catch {
      return ""
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

    let (data, response) = try await URLSession.shared.data(from: url)

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
