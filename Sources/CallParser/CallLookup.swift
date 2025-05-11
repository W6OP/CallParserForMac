//
//  CallLookup.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Algorithms
import Foundation
import os

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
    //hitCache = HitCache<Hit>
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
    //hitCache = HitCache()
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

  // This is for the Demo program
  public func clearCache() async {
    await hitCache.clearCache()
  }

}  // end class

extension CallLookup {
  // MARK: QRZManager Implementation

  /// Logon to QRZ.com
  /// - Parameters:
  ///   - userId: String:
  ///   - password: String:
  /// - Returns: Bool: success or throw
  public func logonToQrz(userId: String, password: String) async throws -> Bool
  {
    var success = false

    // reset if the user corrected his userId
    if userId != previousQrzUserId {
      sessionKeyRequestPending = false
      previousQrzUserId = userId
    }

    qrzUserId = userId
    qrzPassword = password

    do {
      if sessionKeyRequestPending == false {
        if try await requestQRZSessionKey(userId: userId, password: password) {
          success = true
          self.sessionKeyRequestPending = false
        }
      }
    } catch {
      print("getSessionKey failed: \(error.localizedDescription)")
      throw (error)
    }

    return await withCheckedContinuation { continuation in
      continuation.resume(returning: success)
    }
  }

  /// Request a session key from QRZ.com
  /// - Parameters:
  ///   - userId: String
  ///   - password: password descriptionString
  /// - Returns: Bool
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

  /// Determine what kind of error we received and return a friendly description.
  ///
  /// Sometimes there is a trailing space on a message
  /// - Parameter message: String
  /// - Returns: QRZManagerError
  func determineErrorType(message: String) -> QRZManagerError {
    let message = message.trimmed

    if verboseLogging {
      logger.log("Session key request response: \(message)")
    }

    switch message {
    case _ where message == "Session Timeout":
      return QRZManagerError.sessionTimeout
    case _ where message == "Username/password incorrect":
      return QRZManagerError.invalidCredentials
    case _ where message == "Connection refused":
      return QRZManagerError.lockout
    default:
      logger.log("Session key request failed with an unknown error: \(message)")
      return QRZManagerError.unknown
    }
  }
}

// MARK: Lookup Call

extension CallLookup {

  // NOTE: Non async let version - not parallel task
  // Try https://swiftwithmajid.com/2025/03/24/awaiting-multiple-async-tasks-in-swift/?utm_source=substack&utm_medium=email
  public func lookupCallPair(spotter: String, dx: String) async -> [Hit] {
    let spotter = cleanCallSign(callSign: spotter)
    let dx = cleanCallSign(callSign: dx)

    // Direct async let calls without closures
    let spotterStation = await lookupCall(callSign: spotter)
    let dxStation = await lookupCall(callSign: dx)

    // Await the results
    let hits = spotterStation + dxStation
    return hits
  }

  /// Lookup the metadata for a call sign.
  /// - Parameter callSign: String
  /// - Returns: [Hit]
  public func lookupCall(callSign: String) async -> [Hit] {
    var hits: [Hit] = []
    let callSign = cleanCallSign(callSign: callSign)

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
        let hitCollection = processCallSign(call: callSign)
        hits.append(contentsOf: hitCollection)
        if verboseLogging {
          logger.log("\(callSign) retrieved from call parser")
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

  /// Request call sign data from QRZ.com   experimental for xCluster
  /// - Parameters:
  ///   - call: String
  /// - Returns: Hit
  public func requestQRZCallSignData(call: String) async -> Hit? {
    var callSignDictionary: [String: String] = [:]
    var html = ""

    do {
      html = try await qrzManager.requestQRZInformation(call: call)
      callSignDictionary = dataParser.parseCallSignData(html: html)
    } catch {
      if verboseLogging {
        logger.log(
          "Unable to retrieve data from QRZ for \(call) \n\(error.localizedDescription)"
        )
      }
      return nil
    }

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
      logger.log(
        "callSignDictionary[\(call)] is empty: \(String(describing: callSignDictionary["call"])) - \(message)"
      )
      return nil
    }

    let hit = self.buildHit(callSignDictionary: callSignDictionary)
    return hit
  }

  /// Request call sign data from QRZ.com
  /// - Parameters:
  ///   - call: String
  ///   - spotInformation: Tuple
  /// - Returns: Hit
  @available(*, deprecated)
  public func requestQRZCallSignData(
    call: String,
    spotInformation: (spotId: Int, sequence: Int)
  ) async -> Hit? {
    var callSignDictionary: [String: String] = [:]
    var html = ""

    do {
      html = try await qrzManager.requestQRZInformation(call: call)
      callSignDictionary = dataParser.parseCallSignData(html: html)
    } catch {
      if verboseLogging {
        logger.log(
          "Unable to retrieve data from QRZ for \(call) \n\(error.localizedDescription)"
        )
      }
      return nil
    }

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

  /// Try to get the coordinates using the address.
  /// - Parameter callSignDictionary: [String : String]
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

  /// Process an error message form QRZ.com
  /// - Parameter message: String
  func processQRZErrorMessage(message: String) async throws {
    switch message {
    case _ where message.contains("Session Timeout"):
      haveSessionKey = false
      if !qrzUserId.isEmpty && !qrzPassword.isEmpty {
        do {
          logger.log("Session key renewal requested")
          _ = try await logonToQrz(userId: qrzUserId, password: qrzPassword)
        } catch {
          logger.error("Failed to renew session key: \(error)")
          //throw QRZManagerError.unknown
        }
      }
    case _ where message.contains("Connection refused"):
      haveSessionKey = false  // 24 hour lockout
      throw QRZManagerError.lockout
    case _ where message.contains("Username/password incorrect"):
      throw QRZManagerError.invalidCredentials
    case _ where message.contains("not found"):
      throw QRZManagerError.notFound
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
      let lines = contents.components(separatedBy: "\r\n")

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

  /// Clean the call of illegal characters.
  /// - Parameter callSign: String
  /// - Returns: String
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

    if cleanedCallSign.contains("//") {  // EB5KB//P
      cleanedCallSign = cleanedCallSign.replacingOccurrences(
        of: "//",
        with: "/"
      )
    }

    if cleanedCallSign.contains("///") {  // BU1H8///D
      cleanedCallSign = cleanedCallSign.replacingOccurrences(
        of: "///",
        with: "/"
      )
    }

    return cleanedCallSign.trimmingCharacters(in: .controlCharacters)
      .uppercased()
  }
}

// MARK: - Process Callsign

extension CallLookup {

  /// Process a call sign into its component parts ie: W6OP/V31
  /// - Parameter callSign: String
  func processCallSign(
    call: String,
    spotInformation: (spotId: Int, sequence: Int)
  ) -> [Hit] {
    var callStructure = CallStructure(
      callSign: call,
      portablePrefixes: portablePrefixes
    )
    callStructure.spotId = spotInformation.spotId
    callStructure.sequence = spotInformation.sequence

    guard callStructure.callStructureType != .invalid else { return [] }
    return collectMatches(callStructure: callStructure)
  }

  // Experimental for xCluster
  func processCallSign(call: String) -> [Hit] {
    let callStructure = CallStructure(
      callSign: call,
      portablePrefixes: portablePrefixes
    )
    guard callStructure.callStructureType != .invalid else { return [] }
    return collectMatches(callStructure: callStructure)
  }
  /*
   func processCallSign(call: String, spotInformation: (spotId: Int, sequence: Int)) -> [Hit] {
     var hits: [Hit] = []
     var callStructure = CallStructure(callSign: call, portablePrefixes: portablePrefixes)

     callStructure.spotId = spotInformation.spotId
     callStructure.sequence = spotInformation.sequence

     if (callStructure.callStructureType != CallStructureType.invalid) {
       self.collectMatches(callStructure: callStructure, hits: &hits)
     }

     return hits
   }

   // Experimental for xCluster
   func processCallSign(call: String) -> [Hit] {
     var hits: [Hit] = []
     let callStructure = CallStructure(callSign: call, portablePrefixes: portablePrefixes)

     if (callStructure.callStructureType != CallStructureType.invalid) {
       self.collectMatches(callStructure: callStructure, hits: &hits)
     }

     return hits
   }
   */
}

extension CallLookup {
  // MARK: - Collect matches and search the main dictionary.

  /// First see if we can find a match for the max prefix of 4 characters.
  /// Then start removing characters from the back until we can find a match.
  /// Once we have a match we will see if we can find a child that is a better match.
  /// - Parameter callStructure: CallStructure
  func collectMatches(callStructure: CallStructure) -> [Hit] {
    var matches = [PrefixData]()

    switch callStructure.callStructureType {
    case .callPrefix, .prefixCall, .callPortablePrefix, .callPrefixPortable,
      .prefixCallPortable, .prefixCallText:
      if let hits = checkForPortablePrefix(callStructure: callStructure) {
        return hits
      }
    case .callDigit:
      if let hits = checkReplaceCallArea(callStructure: callStructure) {
        return hits
      }
    default:
      break
    }

    matches = searchMainDictionary(structure: callStructure, saveHit: true)
    return buildHit(foundItems: matches, callStructure: callStructure)
  }
  //  func collectMatches(callStructure: CallStructure, hits: inout [Hit]) {
  //    let callStructureType = callStructure.callStructureType
  //    var matches = [PrefixData]()
  //
  //    switch callStructureType {
  //    case .callPrefix, .prefixCall, .callPortablePrefix, .callPrefixPortable, .prefixCallPortable, .prefixCallText:
  //        if checkForPortablePrefix(callStructure: callStructure, hit: &hits) { return }
  //    case .callDigit:
  //        if checkReplaceCallArea(callStructure: callStructure, hits: &hits) { return }
  //    default:
  //        break
  //    }
  //
  //    _ = searchMainDictionary(structure: callStructure, saveHit: true, matches: &matches)
  //    hits = buildHit(foundItems: matches, callStructure: callStructure)
  //  }

  /*
   func collectMatches(callStructure: CallStructure, hits: inout [Hit]) {
     let callStructureType = callStructure.callStructureType
     var matches = [PrefixData]()

     switch (callStructureType)
     {
       case CallStructureType.callPrefix:
         if checkForPortablePrefix(callStructure: callStructure, hit: &hits) { return }

       case CallStructureType.prefixCall:
         if checkForPortablePrefix(callStructure: callStructure, hit: &hits) { return }

       case CallStructureType.callPortablePrefix:
         if checkForPortablePrefix(callStructure: callStructure, hit: &hits) { return }

       case CallStructureType.callPrefixPortable:
         if checkForPortablePrefix(callStructure: callStructure, hit: &hits) { return }

       case CallStructureType.prefixCallPortable:
         if checkForPortablePrefix(callStructure: callStructure, hit: &hits) { return }

       case CallStructureType.prefixCallText:
         if checkForPortablePrefix(callStructure: callStructure, hit: &hits) { return }

       case CallStructureType.callDigit:
         if checkReplaceCallArea(callStructure: callStructure, hits: &hits) { return }

       default:
         break
     }
   */

  /// Search the CallSignDictionary for a hit with the full call. If it doesn't
  /// hit remove characters from the end until hit or there are no letters left.
  /// - Parameters:
  ///   - callStructure: CallStructure
  ///   - saveHit: Bool
  /// - Returns: String
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

  /*
   func searchMainDictionary(structure: CallStructure, saveHit: Bool, matches: inout [PrefixData]) -> String {
     var callStructure = structure
     let baseCall = callStructure.baseCall

     // first we look in all the "." patterns for calls like KG4AA vs KG4AAA
     var firstFourCharacters = (firstLetter: "", secondLetter: "", thirdLetter: "", fourthLetter: "")
     let pattern = determinePatternToUse(callStructure: &callStructure, firstFourCharacters: &firstFourCharacters)
     var stopCharacterFound = false
     let prefixDataList = matchPattern(pattern: pattern, firstFourCharacters: firstFourCharacters, callPrefix: callStructure.prefix!, stopCharacterFound: &stopCharacterFound)

     let localMatches: [PrefixData]
     if prefixDataList.isEmpty {
       return ""
     } else if prefixDataList.count == 1 {
       localMatches = prefixDataList
     } else {
       localMatches = prefixDataList.flatMap { prefixData in
         let maskList = prefixData.getMaskList(first: firstFourCharacters.firstLetter, second: firstFourCharacters.secondLetter, stopCharacterFound: stopCharacterFound)
         return refineList(baseCall: baseCall!, prefixData: prefixData, primaryMaskList: maskList)
       }
     }
     // assign to matches inout param for compatibility
     matches = localMatches
     return matchesFound(saveHit: saveHit, matches: localMatches)
   }
   */

//  func searchMainDictionaryOld(
//    structure: CallStructure,
//    saveHit: Bool,
//    matches: inout [PrefixData]
//  ) -> String {
//    var callStructure = structure
//    let baseCall = callStructure.baseCall
//    //var matches = [PrefixData]()
//    var mainPrefix = ""
//
//    var firstFourCharacters = (
//      firstLetter: "", secondLetter: "", thirdLetter: "", fourthLetter: ""
//    )
//
//    let pattern = determinePatternToUse(
//      callStructure: &callStructure,
//      firstFourCharacters: &firstFourCharacters
//    )
//
//    // first we look in all the "." patterns for calls like KG4AA vs KG4AAA
//    var stopCharacterFound = false
//
//    let prefixDataList = matchPattern(
//      pattern: pattern,
//      firstFourCharacters: firstFourCharacters,
//      callPrefix: callStructure.prefix!,
//      stopCharacterFound: &stopCharacterFound
//    )
//    //let prefixDataList = matchPatternNew(pattern: pattern, firstFourCharacters: firstFourCharacters, callPrefix: callStructure.prefix!, stopCharacterFound: &stopCharacterFound)
//
//    switch prefixDataList.count {
//    case 0:
//      break
//    case 1:
//      matches = prefixDataList
//    default:
//      for prefixData in prefixDataList {
//        let primaryMaskList = prefixData.getMaskList(
//          first: firstFourCharacters.firstLetter,
//          second: firstFourCharacters.secondLetter,
//          stopCharacterFound: stopCharacterFound
//        )
//
//        let tempMatches = refineList(
//          baseCall: baseCall!,
//          prefixData: prefixData,
//          primaryMaskList: primaryMaskList
//        )
//        // now do a union
//        //matches = matches.union(tempMatches)
//        matches.append(contentsOf: tempMatches)
//      }
//    }
//
//    if matches.count > 0 {
//      mainPrefix = matchesFound(saveHit: saveHit, matches: matches)
//      return mainPrefix
//    }
//
//    return mainPrefix
//  }
} // end extension

extension CallLookup {
  // MARK: - Determine the pattern and mask to search with.

  /// Determine the pattern to search with.
  /// - Parameters:
  ///   - callStructure: CallStructure
  ///   - firstFourCharacters: (String, String, String, String)
  /// - Returns: String
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

  /// Build the tuple to match the mask with.
  /// - Parameter prefix: String
  /// - Returns: (String, String, String, String)
  func determineMaskComponents(prefix: String) -> (
    String, String, String, String
  ) {
    var firstFourCharacters = (
      firstLetter: "", secondLetter: "", thirdLetter: "", fourthLetter: ""
    )

    firstFourCharacters.firstLetter = prefix.character(at: 0)!

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

  /// Refine the list.
  /// - Parameters:
  ///   - baseCall: String
  ///   - prefixData: PrefixData
  ///   - primaryMaskList: Set<[[String]]>
  /// - Returns: [PrefixData]
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

//  func refineListOld(
//    baseCall: String,
//    prefixData: PrefixData,
//    primaryMaskList: Set<[[String]]>
//  ) -> [PrefixData] {
//
//    var prefixData = prefixData
//    var matches = [PrefixData]()
//    var rank = 1
//
//    for maskList in primaryMaskList {
//      var position = 2
//      var isPrevious = true
//
//      let smaller = min(baseCall.count, maskList.count)
//
//      for pos in position..<smaller {
//        if maskList[pos].contains(
//          String(baseCall.substring(fromIndex: pos).prefix(1))
//        ) && isPrevious {
//          rank = position + 1
//        } else {
//          isPrevious = false
//          break
//        }
//        position += 1
//      }
//
//      if rank == smaller || maskList.count == 2 {
//        prefixData.searchRank = rank
//        matches.append(prefixData)
//      }
//    }
//
//    return matches
//  }

  /// Build a hit if a match found. Merge multiple hits if requested.
  /// - Parameters:
  ///   - callStructure: CallStructure
  ///   - saveHit: Bool
  ///   - matches: [PrefixData]
  /// - Returns: String
  func matchesFound(saveHit: Bool, matches: [PrefixData]) -> String {

    // TODO: Fix this - it really doesn't do much - not merging hits ever
    if saveHit == false {
      return matches.first!.mainPrefix
    } else {
      if !mergeHits || matches.count == 1 {
        print("Single hit found")
        return ""
      } else {
        print("Multiple hits found")
        // merge multiple hits
        //mergeMultipleHits(matches, callStructure)
      }
    }

    return ""
  }

  /// Find the PrefixData structs that match a specific pattern.
  /// - Parameters:
  ///   - pattern: String
  ///   - firstFourCharacters: (String, String, String, String)
  ///   - callPrefix: String
  ///   - stopCharacterFound: Bool
  /// - Returns: [PrefixData]
//  func matchPatternOld(
//    pattern: String,
//    firstFourCharacters: (
//      firstLetter: String, secondLetter: String, thirdLetter: String,
//      fourthLetter: String
//    ),
//    callPrefix: String,
//    stopCharacterFound: inout Bool
//  ) -> [PrefixData] {
//
//    var prefixDataList = [PrefixData]()
//    var prefix = callPrefix
//    var pattern = pattern.appending(".")
//
//    stopCharacterFound = false
//
//    while pattern.count > 1 {
//
//      guard let query = callSignPatterns[pattern] else {
//        pattern.removeLast()
//        continue
//      }
//
//      for prefixData in query {
//
//        if prefixData.primaryIndexKey.contains(firstFourCharacters.firstLetter)
//          && prefixData.secondaryIndexKey.contains(
//            firstFourCharacters.secondLetter
//          )
//        {
//
//          if pattern.count >= 3
//            && !prefixData.tertiaryIndexKey.contains(
//              firstFourCharacters.thirdLetter
//            )
//          {
//            continue
//          }
//
//          if pattern.count >= 4
//            && !prefixData.quatinaryIndexKey.contains(
//              firstFourCharacters.fourthLetter
//            )
//          {
//            continue
//          }
//
//          var searchRank = 0
//          var prefixData = prefixData
//
//          switch pattern[pattern.count - 1] {
//          case ".":
//            prefix = String(prefix.substring(toIndex: pattern.count - 1))
//
//            if prefixData.setSearchRank(
//              prefix: prefix,
//              excludePortablePrefixes: true,
//              searchRank: &searchRank
//            ) {
//
//              prefixData.searchRank = searchRank
//              prefixDataList.append(prefixData)
//              stopCharacterFound = true
//
//              return prefixDataList
//            }
//          default:
//            prefix = String(prefix.substring(toIndex: pattern.count))
//
//            if prefixData.setSearchRank(
//              prefix: prefix,
//              excludePortablePrefixes: true,
//              searchRank: &searchRank
//            ) {
//
//              prefixData.searchRank = searchRank
//              // check when there should be multiple hits
//              var found = false
//              // can compare objects using == func in prefixData struct
//              for compare in prefixDataList {
//                if compare == prefixData {
//                  found = true
//                }
//              }
//              if !found {
//                prefixDataList.append(prefixData)
//              }
//            }
//          }
//        }
//      }
//      pattern.removeLast()
//    }
//
//    print("old: \(prefixDataList)")
//    return prefixDataList
//  }

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

  /// Check if this is a portable prefix ie: AJ3M/BY1RX.
  /// - Parameter callStructure: CallStructure
  /// - Returns: Bool
  func checkForPortablePrefix(callStructure: CallStructure) -> [Hit]? {
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

    return buildHit(foundItems: topMatches, callStructure: callStructure)
  }
  //  func checkForPortablePrefix(callStructure: CallStructure, hit: inout [Hit]) -> Bool {
  //      // Ensure prefix ends with "/"
  //      guard var prefix = callStructure.prefix else {
  //          return false
  //      }
  //      if !prefix.hasSuffix("/") {
  //          prefix += "/"
  //      }
  //
  //      let patternBuilder = callStructure.buildPattern(candidate: prefix)
  //      let candidates = getPortablePrefixes(prefix: prefix, patternBuilder: patternBuilder)
  //
  //      guard !candidates.isEmpty else {
  //          return false
  //      }
  //
  //      let topMatches: [PrefixData]
  //      if candidates.count == 1 {
  //          topMatches = candidates
  //      } else {
  //          // Find highest searchRank and filter
  //          let maxRank = candidates.lazy.map(\.searchRank).max()!
  //          topMatches = candidates.filter { $0.searchRank == maxRank }
  //      }
  //
  //      hit = buildHit(foundItems: topMatches, callStructure: callStructure)
  //      return true
  //  }

//  func checkForPortablePrefixOld(callStructure: CallStructure, hit: inout [Hit])
//    -> Bool
//  {
//
//    var prefix = callStructure.prefix
//
//    if prefix?.suffix(1) != "/" {
//      prefix = prefix! + "/"
//    }
//
//    let patternBuilder = callStructure.buildPattern(candidate: prefix!)
//
//    var prefixDataList = getPortablePrefixes(
//      prefix: prefix!,
//      patternBuilder: patternBuilder
//    )
//
//    switch prefixDataList.count {
//    case 0:
//      break
//    case 1:
//      hit = buildHit(foundItems: prefixDataList, callStructure: callStructure)
//      return true
//    default:
//      // only keep the highest ranked prefixData for portable prefixes
//      // separates VK0M from VK0H and VP2V and VP2M
//      prefixDataList = prefixDataList.sorted(by: {
//        $0.searchRank < $1.searchRank
//      }).reversed()
//      let ranked = Int(prefixDataList[0].searchRank)
//
//      var tempPrefixDataList: [PrefixData] = []
//      for prefixData in prefixDataList {
//        if prefixData.searchRank == ranked {
//          tempPrefixDataList.append(prefixData)
//        }
//      }
//
//      hit = buildHit(
//        foundItems: tempPrefixDataList,
//        callStructure: callStructure
//      )
//      return true
//    }
//
//    return false
//  }

  /// Portable prefixes are prefixes that end with "/"
  /// - Parameters:
  ///   - prefix: String
  ///   - patternBuilder: String
  /// - Returns: [PrefixData]
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

//  func getPortablePrefixesOld(prefix: String, patternBuilder: String)
//    -> [PrefixData]
//  {
//    var prefixDataList = [PrefixData]()
//    var tempStorage = [PrefixData]()
//    var searchRank = 0
//
//    if let query = portablePrefixes[patternBuilder] {
//      // major performance improvement when I moved this from masksExists
//      let first = prefix[0]
//      let second = prefix[1]
//      let third = prefix[2]
//      let fourth = prefix[3]
//
//      for prefixData in query {
//        tempStorage.removeAll()
//
//        if prefixData.primaryIndexKey.contains(first)
//          && prefixData.secondaryIndexKey.contains(second)
//        {
//
//          if prefix.count >= 3 && !prefixData.tertiaryIndexKey.contains(third) {
//            continue
//          }
//
//          // shortcut to next prefixData if no match on fourth character
//          if prefix.count >= 4 && !prefixData.quatinaryIndexKey.contains(fourth)
//          {
//            continue
//          }
//
//          var prefixData = prefixData
//
//          if prefixData.setSearchRank(
//            prefix: prefix,
//            excludePortablePrefixes: false,
//            searchRank: &searchRank
//          ) {
//            prefixData.searchRank = searchRank
//            tempStorage.append(prefixData)
//            prefixDataList.append(prefixData)
//            // may have to do a union here
//          }
//        }
//      }
//    }
//
//    return prefixDataList
//  }
} // end extension

extension CallLookup {
  // MARK: - Build Hits

  /// Build the hit from the CallParser lookup and add it to the hit list.
  /// - Parameters:
  ///   - foundItems: [PrefixData]
  ///   - callStructure: CallStructure
  func buildHit(foundItems: [PrefixData], callStructure: CallStructure) -> [Hit]
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

      Task {
        // This ensures that model is captured in an immutable way, preventing concurrent mutations.
        [hitCache] in
        await hitCache.updateCache(call, value: hit)
      }
    }
    return hitList
  }

  // TX4YKP
  /// Build the hit from the QRZ callsign data and add it to the hit list.
  /// - Parameter callSignDictionary: [String: String]
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

  // TX4YKP experimental for xCluster
  /// Build the hit from the QRZ callsign data and add it to the hit list.
  /// - Parameter callSignDictionary: [String: String]
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

  /// Returns a copy of hit with verified DXCC information.
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

/*
 // TX4YKP
 /// Build the hit from the QRZ callsign data and add it to the hit list.
 /// - Parameter callSignDictionary: [String: String]
 func buildHit(callSignDictionary: [String: String], spotInformation: (spotId: Int, sequence: Int)) -> Hit {
   var hit = Hit(callSignDictionary: callSignDictionary)
   hit.updateHit(spotId: spotInformation.spotId, sequence: spotInformation.sequence)

   verifyDXCCInformation(hit: &hit)

   Task {
     // This ensures that model is captured in an immutable way, preventing concurrent mutations
     [hitCache] in
     let updatedHit = hit
     let call = updatedHit.call
     await hitCache.updateCache(call, value: updatedHit)
   }

   return hit
 }

 // TX4YKP experimental for xCluster
 /// Build the hit from the QRZ callsign data and add it to the hit list.
 /// - Parameter callSignDictionary: [String: String]
 func buildHit(callSignDictionary: [String: String]) -> Hit {
   var hit = Hit(callSignDictionary: callSignDictionary)

   verifyDXCCInformation(hit: &hit)

   Task {
     // This ensures that model is captured in an immutable way, preventing concurrent mutations.
     [hitCache] in
     let updatedHit = hit
     let call = updatedHit.call
     await hitCache.updateCache(call, value: updatedHit)
   }

   return hit
 }

 /// Verify the DXCC information is correct.
 ///
 /// Sometimes for a dxpedition the operators will put in their own country so you have to
 /// check the entity number and get the actual dxpedition location entity.
 /// - Parameter hit: Hit:
 func verifyDXCCInformation(hit: inout Hit) {

   guard hit.dxcc_entity != 0 else { return }

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
 }
 */

extension CallLookup {
  // MARK: - Call Area Replacement

  /// Check if the call area needs to be replaced and do so if necessary.
  /// If the original call gets a hit, find the MainPrefix and replace
  /// the call area with the new call area. Then do a search with that.
  /// - Parameters:
  ///   - callStructure: CallStructure:
  ///   - hits: [Hit]
  /// - Returns: Bool
  func checkReplaceCallArea(callStructure: CallStructure) -> [Hit]? {
    let digits = callStructure.baseCall.onlyDigits
    var matches = [PrefixData]()

    if callStructure.prefix == String(digits[0]) {
      var updatedStructure = callStructure
      updatedStructure.callStructureType = .call
      return collectMatches(callStructure: updatedStructure)
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
      return collectMatches(callStructure: updatedStructure)
    }

    return nil
  }
  //  func checkReplaceCallArea(callStructure: CallStructure, hits: inout [Hit]) -> Bool {
  //
  //    let digits = callStructure.baseCall.onlyDigits
  //    var position = 0
  //    var matches = [PrefixData]()
  //
  //    // UY0KM/0 - prefix is single digit and same as call
  //    if callStructure.prefix == String(digits[0]) {
  //
  //      var callStructure = callStructure
  //      callStructure.callStructureType = CallStructureType.call
  //      collectMatches(callStructure: callStructure, hits: &hits)
  //      return true
  //    }
  //
  //    // W6OP/4 will get replace by W4
  //    let mainPrefix  = searchMainDictionary(structure: callStructure, saveHit: false, matches: &matches)
  //
  //    if mainPrefix.count > 0 {
  //      var callStructure = callStructure
  //      callStructure.prefix = replaceCallArea(mainPrefix: mainPrefix, prefix: callStructure.prefix, position: &position)
  //
  //      switch callStructure.prefix {
  //
  //      case "":
  //        callStructure.callStructureType = CallStructureType.call
  //
  //      default:
  //        callStructure.callStructureType = CallStructureType.prefixCall
  //      }
  //
  //      collectMatches(callStructure: callStructure, hits: &hits)
  //      return true;
  //    }
  //
  //    return false
  //  }

  /// Replace the call area.
  /// - Parameters:
  ///   - mainPrefix: String:
  ///   - prefix: String:
  /// - Returns: String:
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

  /*
   func replaceCallAreaOld(mainPrefix: String, prefix: String, position: inout Int)
     -> String
   {

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
   */
} // end extension
