//
//  QRZSession.swift
//  CallParser
//
//  Created by Peter Bourget on 4/8/26.
//  Copyright © 2026 Peter Bourget. All rights reserved.
//

import Foundation
import CoreLocation
import os

// MARK: - QRZSession Actor

/// Encapsulates all QRZ.com session state and network interaction.
///
/// This actor owns the session key, credentials, and rate-limiting state,
/// ensuring thread-safe access from concurrent callers. The raw call sign
/// dictionary is returned to the caller (CallLookup) for Hit construction.
public actor QRZSession {

  private let logger = Logger(subsystem: "com.w6op.CallParser", category: "QRZSession")

  // Network + parsing helpers (stateless, Sendable)
  private let qrzManager = QRZManager()
  private let dataParser = DataParser()
  private let geoManager = GeoManager()

  // Session state -- protected by actor isolation
  private var sessionKey: String?
  private var haveSessionKey = false
  private var lastSessionKeyRequestTime: Date?
  private var userId = ""
  private var password = ""
  private var previousUserId = ""

  /// In-flight session-key renewal, shared across concurrent callers to
  /// prevent stampedes (e.g. many simultaneous `Session Timeout` retries).
  private var renewalTask: Task<Bool, Error>?

  /// Whether a valid session key is currently held.
  public var isActive: Bool { haveSessionKey }

  // MARK: - Logon

  /// Logs in to QRZ.com to obtain a session key.
  /// - Parameters:
  ///   - userId: QRZ.com username.
  ///   - password: QRZ.com password.
  /// - Returns: `true` if login and session key retrieval succeeded.
  /// - Throws: `QRZManagerError` on failure.
  public func logon(userId: String, password: String) async throws -> Bool {
    // If the userId changed, invalidate the current session
    if userId != previousUserId {
      previousUserId = userId
      haveSessionKey = false
      sessionKey = nil
    }

    self.userId = userId
    self.password = password

    do {
      return try await ensureSessionKey()
    } catch {
      print("getSessionKey failed: \(error.localizedDescription)")
      throw error
    }
  }

  /// Ensures a valid session key is held, coalescing concurrent renewals.
  ///
  /// If a renewal is already in flight, awaits its result. Otherwise starts
  /// a new renewal task and stores it so subsequent concurrent callers
  /// await the same task rather than each issuing their own network request.
  private func ensureSessionKey() async throws -> Bool {
    if haveSessionKey { return true }

    if let existing = renewalTask {
      return try await existing.value
    }

    guard !userId.isEmpty, !password.isEmpty else { return false }

    let credentials = (userId: userId, password: password)
    let task = Task<Bool, Error> { [self] in
      try await requestSessionKey(
        userId: credentials.userId,
        password: credentials.password
      )
    }
    renewalTask = task
    defer { renewalTask = nil }
    return try await task.value
  }

  // MARK: - Fetch Call Sign Data

  /// Fetches call sign data from QRZ.com and returns the parsed dictionary.
  ///
  /// Handles session timeout recovery (retries once after re-login).
  /// Geocodes the address if coordinates are missing.
  ///
  /// - Parameters:
  ///   - call: The call sign to look up.
  ///   - verboseLogging: Whether to emit detailed log messages.
  /// - Returns: A dictionary of call sign fields, or `nil` on failure.
  public func fetchCallSignData(call: String, verboseLogging: Bool) async -> [String: String]? {

    guard let key = sessionKey else { return nil }

    var callSignDictionary: [String: String] = [:]

    do {
      let html = try await qrzManager.requestQRZInformation(call: call, sessionKey: key)
      callSignDictionary = dataParser.parseCallSignData(html: html)

      if let message = callSignDictionary["Error"] {
        try await processErrorMessage(message: message, verboseLogging: verboseLogging)

        // Retry once after session renewal
        if message.contains("Session Timeout") && haveSessionKey, let newKey = sessionKey {
          let retryHTML = try await qrzManager.requestQRZInformation(call: call, sessionKey: newKey)
          callSignDictionary = dataParser.parseCallSignData(html: retryHTML)

          if let retryMessage = callSignDictionary["Error"] {
            try await processErrorMessage(message: retryMessage, verboseLogging: verboseLogging)
          }
        }
      }
    } catch {
      if verboseLogging {
        logger.log(
          "Unable to retrieve data from QRZ for \(call) \n\(error.localizedDescription)"
        )
      }
      return nil
    }

    // Check for remaining errors after retry
    do {
      if let error = callSignDictionary["Error"] {
        try await processErrorMessage(message: error, verboseLogging: verboseLogging)
      }
    } catch {
      return nil
    }

    // Handle subscription-limited responses by geocoding
    if let message = callSignDictionary["Message"] {
      if verboseLogging {
        logger.log("QRZ message: \(message)")
      }
      guard message.contains("subscription is required") else { return nil }
      await tryGeocodingAddress(&callSignDictionary)
    }

    // Validate coordinates
    guard
      callSignDictionary["lat"] != "0.0" && callSignDictionary["lon"] != "0.0"
    else {
      return nil
    }

    // Validate call sign presence
    guard
      callSignDictionary["call"] != nil && !callSignDictionary["call"]!.isEmpty
    else {
      let message =
        String(callSignDictionary["Error"] ?? "")
        + String(callSignDictionary["Message"] ?? "")
      logger.log(
        "callSignDictionary[\(call)] is empty: \(String(describing: callSignDictionary["call"])) - \(message)"
      )
      return nil
    }

    return callSignDictionary
  }

  // MARK: - Private Helpers

  /// Requests a new QRZ.com session key, enforcing a 60-second rate limit.
  ///
  /// Callers should normally go through ``ensureSessionKey()`` so concurrent
  /// requests are coalesced into a single in-flight renewal.
  private func requestSessionKey(userId: String, password: String) async throws -> Bool {
    if let lastTime = lastSessionKeyRequestTime,
       Date().timeIntervalSince(lastTime) < 60
    {
      throw QRZManagerError.requestTooFrequent
    }

    lastSessionKeyRequestTime = Date()

    let html = await qrzManager.requestSessionKey(userId: userId, password: password)
    let sessionDictionary = dataParser.parseSessionData(html: html)

    if let key = sessionDictionary["Key"], !key.isEmpty {
      print("Received session key")
      haveSessionKey = true
      sessionKey = key
      return true
    } else {
      print("session key request failed: \(sessionDictionary)")
      haveSessionKey = false
      throw determineErrorType(message: sessionDictionary["Error"] ?? "", verboseLogging: false)
    }
  }

  /// Maps a QRZ.com error message to a `QRZManagerError` case.
  private func determineErrorType(message: String, verboseLogging: Bool) -> QRZManagerError {
    let message = message.trimmed
    let normalizedMessage = message.lowercased()

    if verboseLogging {
      logger.log("Session key request response: \(message)")
    }

    switch normalizedMessage {
    case _ where normalizedMessage.contains("session timeout"):
      return QRZManagerError.sessionTimeout
    case _ where normalizedMessage.contains("username/password incorrect"):
      return QRZManagerError.invalidCredentials
    case _ where normalizedMessage.contains("connection refused"):
      return QRZManagerError.lockout
    case _ where normalizedMessage.contains("too many request"):
      return QRZManagerError.requestTooFrequent
    default:
      logger.log("Session key request failed with an unknown error: \(message)")
      return QRZManagerError.unknown
    }
  }

  /// Handles QRZ.com error messages by refreshing session or throwing errors.
  private func processErrorMessage(message: String, verboseLogging: Bool) async throws {
    let normalizedMessage = message.lowercased()

    switch normalizedMessage {
    case _ where normalizedMessage.contains("session timeout"):
      haveSessionKey = false
      sessionKey = nil
      if !userId.isEmpty && !password.isEmpty {
        do {
          logger.log("Session key renewal requested")
          _ = try await ensureSessionKey()
        } catch {
          logger.error("Failed to renew session key: \(error)")
        }
      }
    case _ where normalizedMessage.contains("connection refused"):
      haveSessionKey = false
      throw QRZManagerError.lockout
    case _ where normalizedMessage.contains("username/password incorrect"):
      throw QRZManagerError.invalidCredentials
    case _ where normalizedMessage.contains("not found"):
      throw QRZManagerError.notFound
    case _ where normalizedMessage.contains("too many request"):
      throw QRZManagerError.requestTooFrequent
    default:
      throw QRZManagerError.unknown
    }
  }

  /// Attempts to geocode an address from call sign data if coordinates are missing.
  private func tryGeocodingAddress(_ callSignDictionary: inout [String: String]) async {
    if callSignDictionary["lat"] == nil || callSignDictionary["lon"] == nil {
      do {
        let addr2 = callSignDictionary["addr2"] ?? ""
        let state = callSignDictionary["state"] ?? ""
        let country = callSignDictionary["country"] ?? ""
        let address = "\(addr2), \(state), \(country)"

        let coordinates = try await geoManager.getCoordinatesFromAddress(address: address)
        callSignDictionary["lat"] = String(coordinates.latitude)
        callSignDictionary["lon"] = String(coordinates.longitude)
      } catch {
        logger.log("geo: \(error.localizedDescription)")
        callSignDictionary["lat"] = String(0.0)
        callSignDictionary["lon"] = String(0.0)
      }
    }
  }
}
