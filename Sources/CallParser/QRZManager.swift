////
////  QRZManager.swift
////  xCluster
////
////  Created by Peter Bourget on 7/8/20.
////  Copyright © 2020 Peter Bourget. All rights reserved.
////

import Network
import CoreLocation
import os

// MARK: QRZManager Implementation

public class QRZManager: NSObject {

  // MARK: - Field Definitions

  let logger = Logger(subsystem: "com.w6op.CallParser", category: "QRZManager")

  var dataParser = DataParser()
  var sessionKey: String!
  var qrzUserName = ""
  var qrzPassword = ""
  var useCallLookupOnly = false

  var results: [[String: String]]?         // the whole array of dictionaries
  var sessionDictionary: [String: String]! // the current session dictionary
  var callSignDictionary: [String: String]! // array of key/value pairs

  //  // MARK: - Initialization
  //
  override init() {
    super.init()
  }

  /// Create an http session.
  /// - Parameter host: ClusterIdentifier
  func requestSessionKey(userId: String, password: String) async -> String {

    sessionKey = nil

    // TODO: make this optional so I return nil
    let html = ""
    logger.info("Request Session Key.")

    guard  !userId.isEmpty && !password.isEmpty else {
      logger.info("Missing user name or password.")
      return html
    }

    qrzUserName = userId
    qrzPassword = password

    let urlParameters = "\(qrzUserName);password=\(qrzPassword);agent=com.w6op.CallParser2.0"

    guard let url = URL(string: "https://xmldata.qrz.com/xml/current/?username=\(urlParameters)") else {
      logger.info("Invalid user name or password: \(self.qrzUserName)")
      return html
    }

    do {
      let (data, response) = try await
      URLSession.shared.data(from: url)

      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        print("The server responded with an error")
        return html
      }

      guard let mime = response.mimeType, mime == "application/json" else {
        // if not json do this
        return String(decoding: data, as: UTF8.self)
      }
    } catch {
      return html
    }

    return html
  }


  func requestQRZInformation(call: String) async throws -> String {

    let html = ""

    //sessionKey = "79aab716181b97b9f6dc2c5192917b52"
    guard sessionKey != nil else {
      return html
    }

    URLCache.shared.removeAllCachedResponses()

    let urlParameters = "\(String(self.sessionKey));callsign=\(call)"
    // this dies if session key is missing
    guard let url = URL(string: "https://xmldata.qrz.com/xml/current/?s=\(urlParameters)")
    else { return html }

    let (data, response) = try await
        URLSession.shared.data(from: url)

    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      print("The server responded with an error")
      return html
    }

    guard let mime = response.mimeType, mime == "application/json" else {
      // if not json do this
      return String(decoding: data, as: UTF8.self)
    }

    return html
  }

} // end class
