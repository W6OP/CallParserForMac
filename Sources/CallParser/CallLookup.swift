//
//  CallLookup.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

//import Algorithms
import Foundation
import os

/*
 Changes made 03/12/2026 per ChatGPT
 
 logonToQrz
 Simplifies login flow and removes the old continuation wrapper. It now just returns the real result of requestQRZSessionKey and avoids leaving stale state behind when the username changes.

 requestQRZSessionKey
 Fixes the biggest bug: sessionKeyRequestPending is now always cleared with defer, even if the request fails. That prevents the module from getting stuck thinking a session-key request is still in progress.

 determineErrorType
 Makes QRZ error handling more tolerant by matching lowercase text with contains(...) instead of exact string equality. It also adds recognition of "too many request" as a rate-limit error.

 requestQRZCallSignData(call:)
 Improves session-timeout recovery. If QRZ says the session timed out, the code now tries to renew the session and then retries the lookup once instead of immediately falling back.

 Deprecated requestQRZCallSignData(call:spotInformation:)
 Needs the same fix as the main overload so both code paths behave consistently during session timeout and retry handling.

 processQRZErrorMessage
 Makes QRZ error handling consistent with the new matching logic and adds explicit support for rate-limit errors. It also keeps the session-renewal path for timeout cases.

 loadDXCCEntitiesFile
 Changes line splitting to .newlines, so the CSV loads correctly whether the file uses CRLF or LF line endings.

 matchesFound
 Removes a crash risk by replacing matches.first! with a safe optional access. If the array is unexpectedly empty, it now returns "" instead of crashing.

 determineMaskComponents
 Removes another force-unwrap crash risk on the first character of prefix. If the prefix is empty, it safely returns an empty mask tuple.

 There’s also one extra thing I’d still recommend:
 the deprecated requestQRZCallSignData(call:spotInformation:) in your current file has not been updated yet, so it still uses the older non-retry flow.
 */

// MARK: Class Implementation

/// Parse a call sign and return an object describing the country, dxcc, etc.
public class CallLookup {

  let logger = Logger(subsystem: "com.w6op.CallParser", category: "CallLookup")

  /// Actors
  var hitCache: HitCache<String, Hit>

  var qrzManager = QRZManager()
  let dataParser = DataParser()
  let geoManager = GeoManager()

  var qrzUserId = ""
  var qrzPassword = ""
  var previousQrzUserId = ""
  var haveSessionKey = false
  var sessionKeyRequestPending = false
  var lastSessionKeyRequestTime: Date? = nil
  public var useCallParserOnly = false
  public var verboseLogging = false

  /// local vars
  var callSignList = [String]()
  var adifs: [Int: PrefixData]
  var prefixList = [PrefixData]()
  var callSignPatterns: [String: [PrefixData]]
  var portablePrefixes: [String: [PrefixData]]
  var mergeHits = false
  var cacheMaxCapacity: Int = 10000

  var dxccEntities: [Int: String] = [Int: String]()

  // MARK: - Initializers

  /// Initialization with a QRZ user name and password.
  /// - Parameter prefixFileParser: PrefixFileParser
  public init(
    prefixFileParser: PrefixFileParser,
    qrzUserId: String,
    qrzPassword: String
  ) {
    hitCache = HitCache(maxCapacity: cacheMaxCapacity)

    callSignPatterns = prefixFileParser.callSignPatterns
    portablePrefixes = prefixFileParser.portablePrefixPatterns
    adifs = prefixFileParser.adifs

    qrzManager.qrzUserName = qrzUserId
    qrzManager.qrzPassword = qrzPassword

    loadDXCCEntitiesFile()
  }

  /// Initialization without a QRZ user name and password.
  /// - Parameter prefixFileParser: PrefixFileParser
  public init(prefixFileParser: PrefixFileParser) {
    hitCache = HitCache(maxCapacity: cacheMaxCapacity)

    callSignPatterns = prefixFileParser.callSignPatterns
    portablePrefixes = prefixFileParser.portablePrefixPatterns
    adifs = prefixFileParser.adifs

    loadDXCCEntitiesFile()
  }

  /// Default constructor.
  public init() {
    hitCache = HitCache(maxCapacity: cacheMaxCapacity)

    callSignPatterns = [String: [PrefixData]]()
    portablePrefixes = [String: [PrefixData]]()
    adifs = [Int: PrefixData]()

    loadDXCCEntitiesFile()
  }

  /// Clears all entries from the hit cache asynchronously.
  public func clearLookupCache() async {
    await hitCache.clearCache()
  }

}  // end class

extension CallLookup {
  // MARK: QRZManager Implementation

  /// Logs in to QRZ.com to obtain a session key.
  /// - Parameters:
  ///   - userId: QRZ.com username.
  ///   - password: QRZ.com password.
  /// - Returns: `true` if login and session key retrieval succeeded.
  /// - Throws: `QRZManagerError` on failure.
  public func logonToQrz(userId: String, password: String) async throws -> Bool
  {
    // reset if the user corrected his userId
    if userId != previousQrzUserId {
      sessionKeyRequestPending = false
      previousQrzUserId = userId
    }

    qrzUserId = userId
    qrzPassword = password

    if sessionKeyRequestPending {
      return false
    }

    do {
      return try await requestQRZSessionKey(userId: userId, password: password)
    } catch {
      print("getSessionKey failed: \(error.localizedDescription)")
      throw error
    }
  }
//  public func logonToQrz(userId: String, password: String) async throws -> Bool
//  {
//    var success = false
//
//    // reset if the user corrected his userId
//    if userId != previousQrzUserId {
//      sessionKeyRequestPending = false
//      previousQrzUserId = userId
//    }
//
//    qrzUserId = userId
//    qrzPassword = password
//
//    do {
//      if sessionKeyRequestPending == false {
//        if try await requestQRZSessionKey(userId: userId, password: password) {
//          success = true
//          self.sessionKeyRequestPending = false
//        }
//      }
//    } catch {
//      print("getSessionKey failed: \(error.localizedDescription)")
//      throw (error)
//    }
//
//    return await withCheckedContinuation { continuation in
//      continuation.resume(returning: success)
//    }
//  }

  /// Requests a new QRZ.com session key, enforcing a 60‐second rate limit.
  /// - Parameters:
  ///   - userId: QRZ.com username.
  ///   - password: QRZ.com password.
  /// - Returns: `true` if a new session key was obtained.
  /// - Throws: `QRZManagerError.requestTooFrequent` if called too soon after last request.
  public func requestQRZSessionKey(userId: String, password: String)
    async throws -> Bool
  {

    if let lastTime = lastSessionKeyRequestTime,
      Date().timeIntervalSince(lastTime) < 60
    {
      throw QRZManagerError.requestTooFrequent
    }

    lastSessionKeyRequestTime = Date()
    sessionKeyRequestPending = true
    defer { sessionKeyRequestPending = false }

    let html = await qrzManager.requestSessionKey(
      userId: userId,
      password: password
    )

    let sessionDictionary = await dataParser.parseSessionData(html: html)

    if sessionDictionary["Key"] != nil && !sessionDictionary["Key"]!.isEmpty {
      print("Received session key")
      haveSessionKey = true
      qrzManager.sessionKey = sessionDictionary["Key"]
      return true
    } else {
      print("session key request failed: \(sessionDictionary)")
      haveSessionKey = false
      throw determineErrorType(message: sessionDictionary["Error"] ?? "")
    }
  }

  /// Maps a QRZ.com error message to a `QRZManagerError` case.
  /// - Parameter message: Raw error text from QRZ.com.
  /// - Returns: Corresponding `QRZManagerError`.
  func determineErrorType(message: String) -> QRZManagerError {
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
}

// MARK: Lookup Call

public struct CallPairHits {
  public let spotter: [Hit]
  public let dx: [Hit]
}

extension CallLookup {

  // TODO: lookupCallPair does not preserve which hit belongs to which input
  //It returns [Hit] by concatenating spotter and DX results. That works, but callers
  //have to assume the first chunk belongs to the spotter and the second chunk to DX.
  //If either side returns zero or multiple hits, that can become ambiguous.
  //A tuple or struct would be safer.

  // NOTE: Non async let version - not parallel task
  // Try https://swiftwithmajid.com/2025/03/24/awaiting-multiple-async-tasks-in-swift/?utm_source=substack&utm_medium=email
  /// Performs two  lookups for spotter and DX call signs.
  /// - Parameters:
  ///   - spotter: The spotting station call sign.
  ///   - dx: The DX station call sign.
  /// - Returns: Combined array of `Hit` results.
  @available(*, deprecated, message: "Use lookupCallPairGrouped(spotter:dx:) which returns CallPairHits with separate spotter and dx results.")
  public func lookupCallPair(spotter: String, dx: String) async -> [Hit] {

    let spotterStation = await lookupCall(callSign: spotter)
    let dxStation = await lookupCall(callSign: dx)

    let hits = spotterStation + dxStation
    return hits
  }

  /// Looks up a pair of call signs and returns the results grouped by role.
  /// - Parameters:
  ///   - spotter: The spotting station call sign.
  ///   - dx: The DX station call sign.
  /// - Returns: A ``CallPairHits`` containing separate spotter and dx hit arrays.
  public func lookupCallPairGrouped(
    spotter: String,
    dx: String
  ) async -> CallPairHits {

    let spotterHits = await lookupCall(callSign: spotter)
    let dxHits = await lookupCall(callSign: dx)

    return CallPairHits(
      spotter: spotterHits,
      dx: dxHits
    )
  }

  /// Looks up metadata for a single call sign, using cache, QRZ lookup, or local parser.
  /// - Parameter callSign: The call sign to lookup.
  /// - Returns: Array of `Hit` results (usually one element).
  public func lookupCall(callSign: String) async -> [Hit] {
    var hits: [Hit] = []
    let callSign = cleanCallSign(callSign: callSign)

    guard callSign.isEmpty == false else {
      return hits
    }

    if let hit = await hitCache.checkCache(callSign) {
      hits.append(hit)
      if verboseLogging {
        logger.log("\(callSign) retrieved from cache")
      }
      return hits
    }

    if haveSessionKey && !useCallParserOnly {
      if let hit = await requestQRZCallSignData(call: callSign) {
        hits.append(hit)
        if verboseLogging {
          logger.log("\(callSign) retrieved from QRZ")
        }
      } else {  // requestQRZCallSignData failed
        let hitCollection = processCallSign(call: callSign, cache: false)
        hits.append(contentsOf: hitCollection)
        if verboseLogging {
          logger.log("\(callSign) retrieved from call parser (not cached, QRZ fallback)")
        }
      }

      if verboseLogging {
        let cacheInfo = await hitCache.cacheHitMissRatio()
        logger.log(
          "cache hits: \(cacheInfo.hits) - misses: \(cacheInfo.misses) - ratio: \(Int(cacheInfo.ratio * 100))%"
        )
        let count = await hitCache.count
        logger.log("cache size: \(count)")
      }

      return hits
    }

    // last resort
    let hitCollection = processCallSign(call: callSign)
    hits.append(contentsOf: hitCollection)
    if verboseLogging {
      logger.log("\(callSign) retrieved from call parser")
    }

    return hits
  }
}

// MARK: - QRZ Call Sign Data Request

extension CallLookup {

  /// Fetches call sign data from QRZ.com and builds a `Hit` object.
  /// - Parameter call: The call sign to fetch.
  /// - Returns: A `Hit` if successful; otherwise `nil`.
  public func requestQRZCallSignData(call: String) async -> Hit? {

    var callSignDictionary: [String: String] = [:]
    //var html = ""

    do {
      let html = try await qrzManager.requestQRZInformation(call: call)
      callSignDictionary = dataParser.parseCallSignData(html: html)


      if let message = callSignDictionary["Error"] {
        try await processQRZErrorMessage(message: message)

        if message.contains("Session Timeout") && haveSessionKey {
          let retryHTML = try await qrzManager.requestQRZInformation(call: call)
          callSignDictionary = dataParser.parseCallSignData(html: retryHTML)

          if let retryMessage = callSignDictionary["Error"] {
            try await processQRZErrorMessage(message: retryMessage)
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
//    do {
//      html = try await qrzManager.requestQRZInformation(call: call)
//      callSignDictionary = dataParser.parseCallSignData(html: html)
//    } catch {
//      if verboseLogging {
//        logger.log(
//          "Unable to retrieve data from QRZ for \(call) \n\(error.localizedDescription)"
//        )
//      }
//      return nil
//    }

    do {
      if let error = callSignDictionary["Error"] {
        try await processQRZErrorMessage(message: error)
      }
    } catch {
      return nil
    }

    if let message = callSignDictionary["Message"] {
      if verboseLogging {
        logger.log("QRZ message: \(message)")
      }
      guard message.contains("subscription is required") else { return nil }
      await tryGeocodingAddress(&callSignDictionary)
    }

    guard
      callSignDictionary["lat"] != "0.0" && callSignDictionary["lon"] != "0.0"
    else {
      return nil
    }

    // this happens when the QRZ Session key has expired
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

    let hit = self.buildHit(callSignDictionary: callSignDictionary)
    return hit
  }

  /// Fetches call sign data from QRZ.com and builds a `Hit` object.
  /// - Parameter call: The call sign to fetch.
  /// - Returns: A `Hit` if successful; otherwise `nil`.
  @available(*, deprecated)
  public func requestQRZCallSignData(
    call: String,
    spotInformation: (spotId: Int, sequence: Int)
  ) async -> Hit? {
    var callSignDictionary: [String: String] = [:]
    //var html = ""

    do {
      let html = try await qrzManager.requestQRZInformation(call: call)
      callSignDictionary = dataParser.parseCallSignData(html: html)

      if let message = callSignDictionary["Error"] {
        try await processQRZErrorMessage(message: message)

        if message.contains("Session Timeout") && haveSessionKey {
          let retryHTML = try await qrzManager.requestQRZInformation(call: call)
          callSignDictionary = dataParser.parseCallSignData(html: retryHTML)

          if let retryMessage = callSignDictionary["Error"] {
            try await processQRZErrorMessage(message: retryMessage)
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
//    do {
//      html = try await qrzManager.requestQRZInformation(call: call)
//      callSignDictionary = dataParser.parseCallSignData(html: html)
//    } catch {
//      if verboseLogging {
//        logger.log(
//          "Unable to retrieve data from QRZ for \(call) \n\(error.localizedDescription)"
//        )
//      }
//      return nil
//    }

    do {
      if let message = callSignDictionary["Error"] {
        try await processQRZErrorMessage(message: message)
      }
    } catch {
      return nil
    }

    if let message = callSignDictionary["Message"] {
      if verboseLogging {
        logger.log("QRZ message: \(message)")
      }
      guard message.contains("subscription is required") else { return nil }
      await tryGeocodingAddress(&callSignDictionary)
    }

    guard
      callSignDictionary["lat"] != "0.0" && callSignDictionary["lon"] != "0.0"
    else {
      return nil
    }

    // this happens when the QRZ Session key has expired
    guard
      callSignDictionary["call"] != nil && !callSignDictionary["call"]!.isEmpty
    else {
      let message =
        String(callSignDictionary["Error"] ?? "")
        + String(callSignDictionary["Message"] ?? "")
      logger.log("callSignDictionary[call] empty: \(message)")
      // for debugging
      print("callSignDictionary: \(callSignDictionary)")
      return nil
    }

    let hit = self.buildHit(
      callSignDictionary: callSignDictionary,
      spotInformation: spotInformation
    )
    return hit
  }

  /// Attempts to geocode an address from call sign data if coordinates are missing.
  /// - Parameter callSignDictionary: Dictionary containing address fields and optional lat/lon.
  fileprivate func tryGeocodingAddress(
    _ callSignDictionary: inout [String: String]
  ) async {
    if callSignDictionary["lat"] == nil || callSignDictionary["lon"] == nil {
      do {
        let addr2 = callSignDictionary["addr2"] ?? ""
        let state = callSignDictionary["state"] ?? ""
        let country = callSignDictionary["country"] ?? ""
        let address = ("\(addr2), \(state), \(country)")

        let coordinates = try await geoManager.getCoordinatesFromAddress(
          address: address
        )
        callSignDictionary["lat"] = String(coordinates.latitude)
        callSignDictionary["lon"] = String(coordinates.longitude)
      } catch {
        logger.log("geo: \(error.localizedDescription)")
        callSignDictionary["lat"] = String(0.0)
        callSignDictionary["lon"] = String(0.0)
      }
    }
  }

  /// Handles QRZ.com error messages by refreshing session or throwing errors.
  /// - Parameter message: The error message returned by QRZ.com.
  /// - Throws: A `QRZManagerError` based on the message.
  func processQRZErrorMessage(message: String) async throws {
    let normalizedMessage = message.lowercased()

    switch normalizedMessage {
    case _ where normalizedMessage.contains("session timeout"):
      haveSessionKey = false
      if !qrzUserId.isEmpty && !qrzPassword.isEmpty {
        do {
          logger.log("Session key renewal requested")
          _ = try await logonToQrz(userId: qrzUserId, password: qrzPassword)
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
}

// MARK: - Load files

extension CallLookup {

  /// Load the DXCC Entities file.
  ///
  /// This is used when the QRZ entry has the users dxcc instead of the location dxcc.
  public func loadDXCCEntitiesFile() {

    guard
      let url = Bundle.module.url(
        forResource: "dxccEntities",
        withExtension: "csv"
      )
    else {
      return
      // later make this throw
    }
    do {
      let contents = try String(contentsOf: url, encoding: .utf8)
      //let lines = contents.components(separatedBy: "\r\n")
      let lines = contents.components(separatedBy: .newlines)

      for callSign in lines {
        let components = callSign.split(separator: ",")
        if components.count > 1 {
          dxccEntities[Int(components[1]) ?? 0] = String(components[0])
        }
      }
    } catch {
      // contents could not be loaded
      print("Invalid entity file: ")
    }
  }

  // TODO: - Save to use for city.dat or city.csv
  /// Load the compound call file for testing.
  //  public func loadCompoundFile() {
  //
  //    guard let url = Bundle.module.url(forResource: "pskreporter", withExtension: "csv")  else {
  //      logger.log("Invalid prefix file: ")
  //      return
  //      // later make this throw
  //    }
  //    do {
  //      let contents = try String(contentsOf: url)
  //      let text: [String] = contents.components(separatedBy: "\r\n")
  //      logger.log("Loaded: \(text.count)")
  //      for callSign in text{
  //        callSignList.append(callSign.uppercased())
  //      }
  //    } catch {
  //      // contents could not be loaded
  //      logger.log("Invalid compound file: ")
  //    }
  //  }
}

extension CallLookup {
  // MARK: - Clean Callsign

  /// Cleans and normalizes a raw call sign by trimming whitespace, removing illegal characters, and uppercasing.
  /// - Parameter callSign: Raw input call sign.
  /// - Returns: A cleaned, uppercase call sign without leading/trailing slashes.
  func cleanCallSign(callSign: String) -> String {

    var cleanedCallSign = String(
      callSign.trimmingCharacters(in: .whitespacesAndNewlines)
    )

    // if there are spaces in the call don't process it
    guard !cleanedCallSign.contains(" ") else {
      // SHOULD THROW
      return ""
    }

    guard !cleanedCallSign.contains("%") else {
      return ""
    }

    // don't use switch here as multiple conditions may exist
    // strip leading or trailing "/"  /W6OP/
    if cleanedCallSign.prefix(1) == "/" {
      cleanedCallSign = String(
        cleanedCallSign.suffix(cleanedCallSign.count - 1)
      )
    }

    if cleanedCallSign.suffix(1) == "/" {
      cleanedCallSign = String(
        cleanedCallSign.prefix(cleanedCallSign.count - 1)
      )
    }

    if cleanedCallSign.contains("///") {  // BU1H8///D
      cleanedCallSign = cleanedCallSign.replacingOccurrences(
        of: "///",
        with: "/"
      )
    }

    if cleanedCallSign.contains("//") {  // EB5KB//P
      cleanedCallSign = cleanedCallSign.replacingOccurrences(
        of: "//",
        with: "/"
      )
    }

    // Extract the base callsign from compound calls like F/HB9NBG/P
    // The longest component is the base callsign
    let components = cleanedCallSign.split(separator: "/")
    if components.count > 1,
       let baseCall = components.max(by: { $0.count < $1.count })
    {
      cleanedCallSign = String(baseCall)
    }

    return cleanedCallSign.trimmingCharacters(in: .controlCharacters)
      .uppercased()
  }
}

// MARK: - Process Callsign

extension CallLookup {

  /// Parses a call sign into its component parts using the prefix dictionary.
  /// - Parameters:
  ///   - call: The cleaned call sign.
  ///   - spotInformation: Optional tuple of spot ID and sequence (for DX spots).
  /// - Returns: Array of `Hit` results.
  func processCallSign(
    call: String,
    spotInformation: (spotId: Int, sequence: Int),
    cache: Bool = true
  ) -> [Hit] {
    var callStructure = CallStructure(
      callSign: call,
      portablePrefixes: portablePrefixes
    )
    callStructure.spotId = spotInformation.spotId
    callStructure.sequence = spotInformation.sequence

    guard callStructure.callStructureType != .invalid else { return [] }
    return collectMatches(callStructure: callStructure, cache: cache)
  }

  /// Parses a call sign into its component parts using the prefix dictionary.
  /// - Parameters:
  ///   - call: The cleaned call sign.
  ///   - cache: Whether to cache the results.
  /// - Returns: Array of `Hit` results.
  func processCallSign(call: String, cache: Bool = true) -> [Hit] {
    let callStructure = CallStructure(
      callSign: call,
      portablePrefixes: portablePrefixes
    )
    guard callStructure.callStructureType != .invalid else { return [] }
    return collectMatches(callStructure: callStructure, cache: cache)
  }

} // end extension

extension CallLookup {
  // MARK: - Collect matches and search the main dictionary.

  /// Finds matching prefixes for a given call structure, handling portable and digit cases.
  /// - Parameters:
  ///   - callStructure: The structured call information.
  ///   - cache: Whether to cache the results.
  /// - Returns: Array of matching `Hit` objects.
  func collectMatches(callStructure: CallStructure, cache: Bool = true) -> [Hit] {
    var matches = [PrefixData]()

    switch callStructure.callStructureType {
    case .callPrefix, .prefixCall, .callPortablePrefix, .callPrefixPortable,
      .prefixCallPortable, .prefixCallText:
      if let hits = checkForPortablePrefix(callStructure: callStructure, cache: cache) {
        return hits
      }
    case .callDigit:
      if let hits = checkReplaceCallArea(callStructure: callStructure, cache: cache) {
        return hits
      }
    default:
      break
    }

    matches = searchMainDictionary(structure: callStructure, saveHit: true)
    return buildHit(foundItems: matches, callStructure: callStructure, cache: cache)
  }

  /// Searches the main prefix dictionary for matching `PrefixData`.
  /// - Parameters:
  ///   - structure: The call structure guiding the search.
  ///   - saveHit: Whether to record the match via `matchesFound`.
  /// - Returns: Array of matching `PrefixData`.
  func searchMainDictionary(structure: CallStructure, saveHit: Bool)
    -> [PrefixData]
  {
    var callStructure = structure
    let baseCall = callStructure.baseCall

    var firstFourCharacters = (
      firstLetter: "", secondLetter: "", thirdLetter: "", fourthLetter: ""
    )
    let pattern = determinePatternToUse(
      callStructure: &callStructure,
      firstFourCharacters: &firstFourCharacters
    )
    var stopCharacterFound = false
    let prefixDataList = matchPattern(
      pattern: pattern,
      firstFourCharacters: firstFourCharacters,
      callPrefix: callStructure.prefix!,
      stopCharacterFound: &stopCharacterFound
    )

    let localMatches: [PrefixData]
    if prefixDataList.isEmpty {
      return []
    } else if prefixDataList.count == 1 {
      localMatches = prefixDataList
    } else {
      localMatches = prefixDataList.flatMap { prefixData in
        let maskList = prefixData.getMaskList(
          first: firstFourCharacters.firstLetter,
          second: firstFourCharacters.secondLetter,
          stopCharacterFound: stopCharacterFound
        )
        return refineList(
          baseCall: baseCall!,
          prefixData: prefixData,
          primaryMaskList: maskList
        )
      }
    }

    if saveHit {
      _ = matchesFound(saveHit: true, matches: localMatches)
    }

    return localMatches
  }

} // end extension

extension CallLookup {
  // MARK: - Determine the pattern and mask to search with.

  /// Determines the search pattern and mask components for a call structure.
  /// - Parameters: ...
  /// - Returns: ...
  func determinePatternToUse(
    callStructure: inout CallStructure,
    firstFourCharacters: inout (
      firstLetter: String,
      secondLetter: String,
      thirdLetter: String,
      fourthLetter: String
    )
  ) -> String {
    // Choose the prefix candidate based on the structure type
    let candidate: String
    switch callStructure.callStructureType {
    case .prefixCall, .prefixCallPortable, .prefixCallText:
      // Use existing prefix if present
      candidate = callStructure.prefix ?? callStructure.baseCall
    default:
      // Fallback to baseCall and update prefix
      callStructure.prefix = callStructure.baseCall
      candidate = callStructure.baseCall
    }

    // Compute mask components once
    firstFourCharacters = determineMaskComponents(prefix: candidate)

    // Build and return the pattern
    return callStructure.buildPattern(candidate: candidate)
  }

  /// Determines the search pattern and mask components for a call structure.
  /// - Parameters: ...
  /// - Returns: ...
  func determinePatternToUseOld(
    callStructure: inout CallStructure,
    firstFourCharacters: inout (
      firstLetter: String, secondLetter: String, thirdLetter: String,
      fourthLetter: String
    )
  ) -> String {

    var pattern = ""

    switch callStructure.callStructureType {
    case .prefixCall:
      firstFourCharacters = determineMaskComponents(
        prefix: callStructure.prefix!
      )
      pattern = callStructure.buildPattern(candidate: callStructure.prefix)
    case .prefixCallPortable:
      firstFourCharacters = determineMaskComponents(
        prefix: callStructure.prefix!
      )
      pattern = callStructure.buildPattern(candidate: callStructure.prefix)
    case .prefixCallText:
      firstFourCharacters = determineMaskComponents(
        prefix: callStructure.prefix!
      )
      pattern = callStructure.buildPattern(candidate: callStructure.prefix)
    default:
      callStructure.prefix = callStructure.baseCall
      firstFourCharacters = determineMaskComponents(
        prefix: callStructure.prefix!
      )
      pattern = callStructure.buildPattern(candidate: callStructure.baseCall)
    }

    return pattern
  }

  /// Determines the search pattern and mask components for a call structure.
  /// - Parameters: ...
  /// - Returns: ...
  func determineMaskComponents(prefix: String) -> (
    String, String, String, String
  ) {
    var firstFourCharacters = (
      firstLetter: "", secondLetter: "", thirdLetter: "", fourthLetter: ""
    )

    //firstFourCharacters.firstLetter = prefix.character(at: 0)!
    guard let firstCharacter = prefix.character(at: 0) else {
      return firstFourCharacters
    }
    firstFourCharacters.firstLetter = firstCharacter

    if prefix.count > 1 {
      firstFourCharacters.secondLetter = prefix.character(at: 1)!
    }

    if prefix.count > 2 {
      firstFourCharacters.thirdLetter = prefix.character(at: 2)!
    }

    if prefix.count > 3 {
      firstFourCharacters.fourthLetter = prefix.character(at: 3)!
    }

    return firstFourCharacters
  }

  // MARK: - Matching Patterns

  /// Refines a set of mask lists into `PrefixData` hits based on matching character positions.
  /// - Parameters:
  ///   - baseCall: The full call string.
  ///   - prefixData: Initial `PrefixData` to refine.
  ///   - primaryMaskList: Set of possible masks.
  /// - Returns: Filtered and ranked array of `PrefixData`.
  func refineList(
    baseCall: String,
    prefixData: PrefixData,
    primaryMaskList: Set<[[String]]>
  ) -> [PrefixData] {
    // Optimized version: precompute base characters and compute search rank per mask
    var matches = [PrefixData]()
    let baseChars = Array(baseCall)

    for mask in primaryMaskList {
      let maxIndex = min(mask.count, baseChars.count)
      var matchLength = 0
      // Check from position 2 up to maxIndex
      for i in 2..<maxIndex {
        if mask[i].contains(String(baseChars[i])) {
          matchLength += 1
        } else {
          break
        }
      }
      // Account for the first two characters plus matched suffix length
      let rank = (matchLength > 0) ? matchLength + 2 : 1
      if mask.count == 2 || rank == maxIndex {
        var data = prefixData
        data.searchRank = rank
        matches.append(data)
      }
    }
    return matches
  }

  /// Handles saving or merging hits and returns a main prefix string.
  /// - Parameters:
  ///   - saveHit: Whether to save the hit.
  ///   - matches: Matched `PrefixData` array.
  /// - Returns: The main prefix string or empty if multiple/merged.
  func matchesFound(saveHit: Bool, matches: [PrefixData]) -> String {

    if saveHit == false {
      return matches.first?.mainPrefix ?? ""
    } else {
      if !mergeHits || matches.count == 1 {
        return ""
      } else {
        print("Multiple hits found")
      }
    }

    return ""
  }
//  func matchesFound(saveHit: Bool, matches: [PrefixData]) -> String {
//
//    // TODO: Fix this - it really doesn't do much - not merging hits ever
//    if saveHit == false {
//      return matches.first!.mainPrefix
//    } else {
//      if !mergeHits || matches.count == 1 {
//        //print("Single hit found")
//        return ""
//      } else {
//        print("Multiple hits found")
//        // merge multiple hits
//        //mergeMultipleHits(matches, callStructure)
//      }
//    }
//
//    return ""
//  }

  /// Iteratively matches decreasing patterns against the prefix dictionary until hits are found.
  /// - Returns: Array of `PrefixData` for the first match set.
  func matchPattern(
    pattern: String,
    firstFourCharacters: (
      firstLetter: String, secondLetter: String, thirdLetter: String,
      fourthLetter: String
    ),
    callPrefix: String,
    stopCharacterFound: inout Bool
  ) -> [PrefixData] {

    var prefixDataList = [PrefixData]()
    let prefix = callPrefix
    var modifiedPattern = pattern + "."
    stopCharacterFound = false

    while modifiedPattern.count > 1 {
      // Access query if available, or trim pattern and continue
      guard let query = callSignPatterns[modifiedPattern] else {
        modifiedPattern.removeLast()
        continue
      }

      for var prefixData in query {
        // Filter by primary and secondary index keys first
        if prefixData.primaryIndexKey.contains(firstFourCharacters.firstLetter),
          prefixData.secondaryIndexKey.contains(
            firstFourCharacters.secondLetter
          )
        {

          // Apply conditional checks on tertiary and quaternary index keys
          if modifiedPattern.count >= 3,
            !prefixData.tertiaryIndexKey.contains(
              firstFourCharacters.thirdLetter
            )
          {
            continue
          }
          if modifiedPattern.count >= 4,
            !prefixData.quatinaryIndexKey.contains(
              firstFourCharacters.fourthLetter
            )
          {
            continue
          }

          // Determine prefix for setSearchRank based on the last character of modifiedPattern
          let isStopCharacter = modifiedPattern.last == "."
          let prefixLength =
            isStopCharacter ? modifiedPattern.count - 1 : modifiedPattern.count
          let searchPrefix = String(prefix.prefix(prefixLength))

          // Set search rank and add to list if successful
          var searchRank = 0
          if prefixData.setSearchRank(
            prefix: searchPrefix,
            excludePortablePrefixes: true,
            searchRank: &searchRank
          ) {
            prefixData.searchRank = searchRank

            // If stop character found, append to list and exit early
            if isStopCharacter {
              prefixDataList.append(prefixData)
              stopCharacterFound = true
              return prefixDataList
            }

            // Append unique prefix data if not a duplicate
            if !prefixDataList.contains(where: { $0 == prefixData }) {
              prefixDataList.append(prefixData)
            }
          }
        }
      }
      modifiedPattern.removeLast()
    }

    return prefixDataList
  }
}

// MARK: - Portable Prefixes

extension CallLookup {

  /// Checks for portable-prefix formats (e.g., VK4AAA/3) and returns hits.
  func checkForPortablePrefix(callStructure: CallStructure, cache: Bool = true) -> [Hit]? {
    guard var prefix = callStructure.prefix else { return nil }
    if !prefix.hasSuffix("/") {
      prefix += "/"
    }

    let pattern = callStructure.buildPattern(candidate: prefix)
    let candidates = getPortablePrefixes(
      prefix: prefix,
      patternBuilder: pattern
    )

    guard !candidates.isEmpty else { return nil }

    let topMatches: [PrefixData]
    if candidates.count == 1 {
      topMatches = candidates
    } else {
      let maxRank = candidates.lazy.map(\.searchRank).max()!
      topMatches = candidates.filter { $0.searchRank == maxRank }
    }

    return buildHit(foundItems: topMatches, callStructure: callStructure, cache: cache)
  }

  /// Retrieves portable prefix entries matching the given pattern and ranks them.
  func getPortablePrefixes(prefix: String, patternBuilder: String)
    -> [PrefixData]
  {
    // Quick exit if no candidates
    guard let candidates = portablePrefixes[patternBuilder], !candidates.isEmpty
    else {
      return []
    }

    // Pre-extract characters once
    let first = prefix[prefix.startIndex]
    let second =
      prefix.index(prefix.startIndex, offsetBy: 1, limitedBy: prefix.endIndex)
      .map { prefix[$0] } ?? prefix[prefix.startIndex]
    let third =
      prefix.count > 2
      ? prefix[prefix.index(prefix.startIndex, offsetBy: 2)] : first
    let fourth =
      prefix.count > 3
      ? prefix[prefix.index(prefix.startIndex, offsetBy: 3)] : second

    var bestRank = 0
    var results = [PrefixData]()

    for var prefixData in candidates {
      // Filter by index keys
      guard prefixData.primaryIndexKey.contains(String(first)),
        prefixData.secondaryIndexKey.contains(String(second)),
        prefix.count < 3 || prefixData.tertiaryIndexKey.contains(String(third)),
        prefix.count < 4
          || prefixData.quatinaryIndexKey.contains(String(fourth))
      else {
        continue
      }

      var rank = 0
      if prefixData.setSearchRank(
        prefix: prefix,
        excludePortablePrefixes: false,
        searchRank: &rank
      ) {
        prefixData.searchRank = rank

        // Keep only the highest-ranked matches
        if rank > bestRank {
          bestRank = rank
          results = [prefixData]
        } else if rank == bestRank {
          results.append(prefixData)
        }
      }
    }

    return results
  }

} // end extension

extension CallLookup {
  // MARK: - Build Hits

  /// Builds `Hit` objects from prefix or QRZ data and optionally caches them.
  /// - Parameters:
  ///   - foundItems: Matched `PrefixData` array.
  ///   - callStructure: The structured call information.
  ///   - cache: Whether to cache the results. Pass `false` when the hit is a
  ///     fallback result that should be re-fetched later (e.g. QRZ session timeout).
  /// - Returns: Array of `Hit` objects.
  func buildHit(foundItems: [PrefixData], callStructure: CallStructure, cache: Bool = true) -> [Hit]
  {
    var hitList: [Hit] = []
    let call = callStructure.fullCall

    let listByRank = foundItems.sorted(by: {
      (prefixData0: PrefixData, prefixData1: PrefixData) -> Bool in
      return prefixData0.searchRank < prefixData1.searchRank
    })

    for prefixData in listByRank {
      var hit = Hit(callSign: call, prefixData: prefixData)
      hit.updateHit(
        spotId: callStructure.spotId,
        sequence: callStructure.sequence
      )
      hitList.append(hit)

      if cache {
        Task {
          // This ensures that model is captured in an immutable way, preventing concurrent mutations.
          [hitCache] in
          await hitCache.updateCache(call, value: hit)
        }
      }
    }
    return hitList
  }

  /// Builds `Hit` objects from prefix or QRZ data and caches them.
  func buildHit(
    callSignDictionary: [String: String],
    spotInformation: (spotId: Int, sequence: Int)
  ) -> Hit {
    let originalHit = Hit(callSignDictionary: callSignDictionary)
    var updatedHit = originalHit

    updatedHit.updateHit(
      spotId: spotInformation.spotId,
      sequence: spotInformation.sequence
    )
    let verifiedHit = verifiedDXCCInformation(for: updatedHit)

    Task {
      [hitCache] in
      let call = verifiedHit.call
      await hitCache.updateCache(call, value: verifiedHit)
    }

    return verifiedHit
  }

  /// Builds `Hit` objects from prefix or QRZ data and caches them.
  func buildHit(callSignDictionary: [String: String]) -> Hit {
    let originalHit = Hit(callSignDictionary: callSignDictionary)
    let verifiedHit = verifiedDXCCInformation(for: originalHit)

    Task {
      [hitCache] in
      let call = verifiedHit.call
      await hitCache.updateCache(call, value: verifiedHit)
    }

    return verifiedHit
  }

  /// Returns a copy of `Hit` with corrected DXCC entity country if mismatched.
  private func verifiedDXCCInformation(for hit: Hit) -> Hit {
    var hit = hit

    guard hit.dxcc_entity != 0 else { return hit }

    if let country = dxccEntities[hit.dxcc_entity]?.trimmed {
      let hitCountry = String(hit.country.trimmed)

      if country.localizedCaseInsensitiveCompare(hitCountry) != .orderedSame {
        hit.country = country

        if verboseLogging {
          let call = hit.call
          logger.log("\(hitCountry) replaced with \(country): \(call)")
        }
      }
    } else {
      hit.country = "invalid dxcc: \(hit.dxcc_entity)"
    }

    return hit
  }

}  // end extension

extension CallLookup {
  // MARK: - Call Area Replacement

  /// Replaces the call area in the prefix if initial lookup fails and retries matching.
  func checkReplaceCallArea(callStructure: CallStructure, cache: Bool = true) -> [Hit]? {
    let digits = callStructure.baseCall.onlyDigits
    var matches = [PrefixData]()

    if callStructure.prefix == String(digits[0]) {
      var updatedStructure = callStructure
      updatedStructure.callStructureType = .call
      return collectMatches(callStructure: updatedStructure, cache: cache)
    }

    matches = searchMainDictionary(structure: callStructure, saveHit: false)
    let mainPrefix = matches.first?.mainPrefix ?? ""

    if !mainPrefix.isEmpty {
      var updatedStructure = callStructure
      updatedStructure.prefix = replaceCallArea(
        mainPrefix: mainPrefix,
        prefix: callStructure.prefix
      )

      updatedStructure.callStructureType =
        updatedStructure.prefix.isEmpty ? .call : .prefixCall
      return collectMatches(callStructure: updatedStructure, cache: cache)
    }

    return nil
  }

  /// Computes a new prefix by replacing the call area based on main prefix rules.
  /// - Parameters:
  ///   - mainPrefix: The original main prefix string.
  ///   - prefix: The remainder of the call string.
  /// - Returns: New prefix string including "/" delimiter.
  func replaceCallArea(mainPrefix: String, prefix: String) -> String
  {
    var position = 0
    let oneCharPrefixes: [String] = ["I", "K", "N", "W", "R", "U"]
    let XNUM_SET: [String] = [
      "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "#", "[",
    ]

    switch mainPrefix.count {
    case 1:
      if oneCharPrefixes.contains(mainPrefix[0]) {
        // I9MRY/1 - mainPrefix = I --> I1
        position = 2
      } else if mainPrefix.isAlphabetic {
        // FA3L/6 - mainPrefix is F
        position = 99
        return ""
      }

    case 2:
      if oneCharPrefixes.contains(mainPrefix[0])
        && XNUM_SET.contains(mainPrefix[1])
      {
        // W6OP/4 - main prefix = W6 --> W4
        position = 2
      } else {
        // AL7NS/4 - main prefix = KL --> KL4
        position = 3
      }

    default:
      if oneCharPrefixes.contains(mainPrefix[0])
        && XNUM_SET.contains(mainPrefix[1])
      {
        position = 2
      } else {
        if XNUM_SET.contains(mainPrefix[2]) {
          // JI3DT/6 - mainPrefix = JA3 --> JA6
          position = 3
        } else {
          // 3DLE/1 - mainprefix = 3DA --> 3DA1
          position = 4
        }
      }
    }

    // append call area to mainPrefix
    return mainPrefix.prefix(position - 1) + prefix + "/"
  }

} // end extension
