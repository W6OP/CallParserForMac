//
//  CallLookup.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation
import os

// MARK: Class Implementation

/// Parse a call sign and return an object describing the country, dxcc, etc.
public class CallLookup {

  let logger = Logger(subsystem: "com.w6op.CallParser", category: "CallLookup")

  /// Actors
  var hitCache: HitCache

  var qrzManager = QRZManager()
  let dataParser = DataParser()

  var qrzUserId = ""
  var qrzPassword = ""
  var haveSessionKey = false
  var sessionKeyRequestPending = false
  public var useCallParserOnly = false

  /// local vars
  var callSignList = [String]()
  var adifs: [Int : PrefixData]
  var prefixList = [PrefixData]()
  var callSignPatterns: [String: [PrefixData]]
  var portablePrefixes: [String: [PrefixData]]
  var mergeHits = false

  var dxccEntities: [Int: String] = [Int: String]()
  
  // MARK: - Initializers

  /// Initialization with a QRZ user name and password.
  /// - Parameter prefixFileParser: PrefixFileParser
  public init(prefixFileParser: PrefixFileParser, qrzUserId: String, qrzPassword: String) {
    hitCache = HitCache()

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
    hitCache = HitCache()

    callSignPatterns = prefixFileParser.callSignPatterns
    portablePrefixes = prefixFileParser.portablePrefixPatterns
    adifs = prefixFileParser.adifs

    loadDXCCEntitiesFile()
  }

  /// Default constructor.
  public init() {
    hitCache = HitCache()

    callSignPatterns = [String: [PrefixData]]()
    portablePrefixes = [String: [PrefixData]]()
    adifs = [Int : PrefixData]()

    loadDXCCEntitiesFile()
  }

  // MARK: QRZManager Implementation

  /// Logon to QRZ.com
  /// - Parameters:
  ///   - userId: String:
  ///   - password: String:
  /// - Returns: Bool: success or throw
  public func logonToQrz(userId: String, password: String) async throws -> Bool {
    var success = false

    qrzUserId = userId
    qrzPassword = password

    do {
      if sessionKeyRequestPending == false {
        success = try await getSessionKeyEx(userId: userId, password: password)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
        // delay to prevent multiple requests
        self.sessionKeyRequestPending = false
      }
    } catch {
      print("getSessionKey failed: \(error.localizedDescription)")
      throw(error)
    }

    return await withCheckedContinuation { continuation in
          continuation.resume(returning: success)
    }
  }

  /// Request a session key from QRZ.com
  /// - Parameters:
  ///   - userId: String
  ///   - password: String
  /// - Returns: Bool: success or throw
//  public func getSessionKey(userId: String, password: String) async throws -> Bool {
//
//    sessionKeyRequestPending = true
//
//    let data = try await qrzManager.requestSessionKey(userId: userId, password: password)
//    let sessionDictionary = await qrzManager.parseSessionData(data: data)
//
//    if sessionDictionary["Key"] != nil && !sessionDictionary["Key"]!.isEmpty {
//      print("Received session key")
//      self.haveSessionKey = true
//      self.qrzManager.sessionKey = sessionDictionary["Key"]
//      return true
//    } else {
//      print("session key request failed: \(sessionDictionary)")
//      self.haveSessionKey = false
//      throw determineErrorType(message: sessionDictionary["GMTime"] ?? "")
//    }
//  }


  public func getSessionKeyEx(userId: String, password: String) async throws -> Bool {

    sessionKeyRequestPending = true

    let html = try await qrzManager.requestSessionKeyEx(userId: userId, password: password)

    let sessionDictionary = await dataParser.parseSessionData(html: html)

    if sessionDictionary["Key"] != nil && !sessionDictionary["Key"]!.isEmpty {
      print("Received session key")
      self.haveSessionKey = true
      self.qrzManager.sessionKey = sessionDictionary["Key"]
      return true
    } else {
      print("session key request failed: \(sessionDictionary)")
      self.haveSessionKey = false
      throw determineErrorTypeEx(message: sessionDictionary["Error"] ?? "")
    }
  }

  func determineErrorTypeEx(message: String) -> QRZManagerError {
    switch message {
    case _ where message == "Session Timeout":
      return QRZManagerError.sessionTimeout
    case _ where message == "Username/password incorrect":
      return QRZManagerError.invalidCredentials
    case _ where message == "Connection refused":
      return QRZManagerError.lockout
    default:
      logger.log("determineErrorType unknown error: \(message)")
      return QRZManagerError.unknown
    }
  }

  /// Determine what kind of error to throw.
  ///
  ///  "Username/password incorrect \nTue Sep 20 14:28:11 2022"
  ///  "Session Timeout"
  /// - Parameter message: String:
  /// - Returns: QRZManagerError:
  func determineErrorType(message: String) -> QRZManagerError {

    switch message {
    case _ where message.contains("Session Timeout"):
      return QRZManagerError.sessionTimeout
    case _ where message.contains("Username/password incorrect"):
      return QRZManagerError.invalidCredentials
    case _ where message.contains("Connection refused"):
      return QRZManagerError.lockout
    default:
      logger.log("determineErrorType unknown error: \(message)")
      return QRZManagerError.unknown
    }
  }

  // MARK: - Lookup Call

  // TX4YKP
  /// Clear the Hit cache.
  public func clearCache() {
    Task {
      await hitCache.removeAll()
    }
  }

  ///Retrieve the hit data for a single call sign using a continuation.
  ///
  /// Clean the callsign of illegal characters. Returned uppercased.
  /// Check the cache and return the hit if it exists.
  /// else -> use the CallParser to get the hit.
  /// - Parameter call: String: call sign.
  /// - Returns: [Hit]
  public func lookupCall(call: String) async -> [Hit] {
    let callSignUpper = cleanCallSign(callSign: call)
    let spotInformation = (spotId: 0, sequence: 0)

    return await withCheckedContinuation { continuation in
      Task {
        if let hit = await hitCache.checkCache(call: callSignUpper) {
          var hits: [Hit] = []
          hits.append(hit)
          continuation.resume(returning: hits)
        } else if haveSessionKey  && !useCallParserOnly {
          if let hit = await requestQRZDataEx(call: callSignUpper, spotInformation: spotInformation) {
            var hits: [Hit] = []
            print (hit)
            hits.append(hit)
            continuation.resume(returning: hits)
          } else {
            let hits = processCallSign(call: callSignUpper, spotInformation: spotInformation)
            continuation.resume(returning: hits)
          }
        } else {
          let hits = processCallSign(call: callSignUpper, spotInformation: spotInformation)
          continuation.resume(returning: hits)
        }
      }
    }
  }

  /// Retrieve the hit data for a pair of call signs using a continuation.
  ///
  /// Clean the callsign of illegal characters. Returned uppercased.
  /// Check the cache and return the hit if it exists.
  /// else -> use the CallParser to get the hit.
  /// - Parameters:
  ///   - spotter: String: the spotter station call sign.
  ///   - dx: String: the dx station call sign.
  /// - Returns: [Hit]
  public func lookupCall(spotter: String, dx: String) async -> [Hit] {
    let spotterCall = cleanCallSign(callSign: spotter)
    let dxCall = cleanCallSign(callSign: dx)
    let spotInformation = (spotId: 0, sequence: 0)

    return await withCheckedContinuation { continuation in
      Task {
        var hits: [Hit] = []
        if let spotterHit = await hitCache.checkCache(call: spotterCall) {
          hits.append(spotterHit)
        } else if haveSessionKey  && !useCallParserOnly {
          if let hit = await requestQRZDataEx(call: spotterCall, spotInformation: spotInformation) {
            hits.append(hit)
          } else {
            let hitCollection = processCallSign(call: spotterCall, spotInformation: spotInformation)
            hits.append(contentsOf: hitCollection)
          }
        } else {
          let hitCollection = processCallSign(call: spotterCall, spotInformation: spotInformation)
          hits.append(contentsOf: hitCollection)
        }

        if let dxHit = await hitCache.checkCache(call: dxCall) {
          hits.append(dxHit)
        } else if haveSessionKey  && !useCallParserOnly {
          if let hit = await requestQRZDataEx(call: dxCall, spotInformation: spotInformation) {
            hits.append(hit)
          } else {
            let hitCollection = processCallSign(call: dxCall, spotInformation: spotInformation)
            hits.append(contentsOf: hitCollection)
          }
        } else {
          let hitCollection = processCallSign(call: dxCall, spotInformation: spotInformation)
          hits.append(contentsOf: hitCollection)
        }

        continuation.resume(returning: hits)
      }
    }
  }

  /// Retrieve the hit data for a pair of call signs with sequence numbers.
  ///
  /// Clean the callsign of illegal characters. Returned uppercased.
  /// Check the cache and return the hit if it exists.
  /// else -> use the CallParser to get the hit.
  /// - Parameters:
  ///   - spotter: Tuple: the spotter station call sign and sequence number.
  ///   - dx: Tuple: the dx station call sign and sequence number.
  /// - Returns: [Hit]
  public func lookupCallPair(spotter: (call: String, sequence: Int), dx: (call: String, sequence: Int)) async -> [Hit] {
    let spotterCall = cleanCallSign(callSign: spotter.call)
    let dxCall = cleanCallSign(callSign: dx.call)

    return await withCheckedContinuation { continuation in
      Task {
        var hits: [Hit] = []
        var spotInformation = (spotId: 0, sequence: spotter.sequence)

        if let spotterHit = await hitCache.checkCache(call: spotterCall) {
          var spotterHit = spotterHit
          spotterHit.sequence = spotter.sequence
          hits.append(spotterHit)
        } else if haveSessionKey  && !useCallParserOnly {
          if let hit = await requestQRZDataEx(call: spotterCall, spotInformation: spotInformation) {
            hits.append(hit)
          } else {
            let hitCollection = processCallSign(call: spotterCall, spotInformation: spotInformation)
            hits.append(contentsOf: hitCollection)
          }
        } else {
          let hitCollection = processCallSign(call: spotterCall, spotInformation: spotInformation)
          hits.append(contentsOf: hitCollection)
        }

        spotInformation = (spotId: 0, sequence: dx.sequence)
        if let dxHit = await hitCache.checkCache(call: dxCall) {
          var dxHit = dxHit
          dxHit.sequence = dx.sequence
          hits.append(dxHit)
        } else if haveSessionKey  && !useCallParserOnly {
          if let hit = await requestQRZDataEx(call: dxCall, spotInformation: spotInformation) {
            hits.append(hit)
          } else {
            let hitCollection = processCallSign(call: dxCall, spotInformation: spotInformation)
            hits.append(contentsOf: hitCollection)
          }
        } else {
          let hitCollection = processCallSign(call: dxCall, spotInformation: spotInformation)
          hits.append(contentsOf: hitCollection)
        }

         continuation.resume(returning: hits)
      }
    }
  }

  public func lookupCallPair(spotter: (call: String, sequence: Int, spotId: Int), dx: (call: String, sequence: Int, spotId: Int)) async -> [Hit] {
    let spotterCall = cleanCallSign(callSign: spotter.call)
    let dxCall = cleanCallSign(callSign: dx.call)

    return await withCheckedContinuation { continuation in
      Task {
        var hits: [Hit] = []
        var spotInformation = (spotId: spotter.spotId, sequence: spotter.sequence)

        if let spotterHit = await hitCache.checkCache(call: spotterCall) {
          var spotterHit = spotterHit
          spotterHit.sequence = spotter.sequence
          spotterHit.spotId = spotter.spotId
          hits.append(spotterHit)
        } else if haveSessionKey  && !useCallParserOnly {
          if let hit = await requestQRZDataEx(call: spotterCall, spotInformation: spotInformation) {
            hits.append(hit)
          } else {
            let hitCollection = processCallSign(call: spotterCall, spotInformation: spotInformation)
            hits.append(contentsOf: hitCollection)
          }
        } else {
          let hitCollection = processCallSign(call: spotterCall, spotInformation: spotInformation)
          hits.append(contentsOf: hitCollection)
        }

        spotInformation = (spotId: dx.spotId, sequence: dx.sequence)
        if let dxHit = await hitCache.checkCache(call: dxCall) {
          var dxHit = dxHit
          dxHit.sequence = dx.sequence
          dxHit.spotId = dx.spotId
          hits.append(dxHit)
        } else if haveSessionKey  && !useCallParserOnly {
          if let hit = await requestQRZDataEx(call: dxCall, spotInformation: spotInformation) {
            hits.append(hit)
          } else {
            let hitCollection = processCallSign(call: dxCall, spotInformation: spotInformation)
            hits.append(contentsOf: hitCollection)
          }
        } else {
          let hitCollection = processCallSign(call: dxCall, spotInformation: spotInformation)
          hits.append(contentsOf: hitCollection)
        }

         continuation.resume(returning: hits)
      }
    }
  }

  /// If a QRZ.com xml account is available and credentials are supplied look up the call
  /// there first. if the call is not available from QRZ then use the call parser.
  /// - Parameters:
  ///   - call: String: call sign to look up.
  ///   - spotInformation: SpotInformation: User defined data to return with the hit.
//  public func requestQRZData (call: String, spotInformation: (spotId: Int, sequence: Int)) async -> Hit? {
//
//    do {
//      if let data = try await qrzManager.requestQRZInformation(call: call) {
//        let result = await self.qrzManager.parseReceivedData(data: data, spotInformation: spotInformation)
//        let callSignDictionary = result.0
//        let spotInformation = result.1
//
//        if callSignDictionary["call"] != nil && !callSignDictionary["call"]!.isEmpty {
//          let hit = self.buildHit(callSignDictionary: callSignDictionary, spotInformation: spotInformation)
//          return hit
//        } else {
//          if let message = callSignDictionary["Error"] {
//            // do I want to throw here???
//            try processQRZErrorMessage(message: message)
//          }
//          else {
//            logger.log("call sign dictionary error: \(callSignDictionary)")
//          }
//        }
//      }
//    } catch {
//      return nil
//    }
//
//    return nil
//  }

  public func requestQRZDataEx(call: String, spotInformation: (spotId: Int, sequence: Int)) async -> Hit? {

    do {
      let html = try await qrzManager.requestQRZInformationEx(call: call)
      let result = dataParser.parseReceivedData(html: html, spotInformation: spotInformation)
      let callSignDictionary = result.0
      let spotInformation = result.1

      if callSignDictionary["call"] != nil && !callSignDictionary["call"]!.isEmpty {
        let hit = self.buildHit(callSignDictionary: callSignDictionary, spotInformation: spotInformation)
        return hit
      } else {
        if let message = callSignDictionary["Error"] {
          // do I want to throw here???
          try processQRZErrorMessage(message: message)
        }
        else {
          logger.log("call sign dictionary error: \(callSignDictionary)")
        }
      }
    } catch {
      return nil
    }

    return nil
  }

  func processQRZErrorMessage(message: String) throws {
    switch message {
    case _ where message.contains("Session Timeout"):
      haveSessionKey = false 
      if !qrzUserId.isEmpty && !qrzPassword.isEmpty {
        Task {
          do {
            logger.log("Session key renewal requested")
            _ =  try await logonToQrz(userId: qrzUserId, password: qrzPassword)
          } catch {
            throw QRZManagerError.unknown
          }
        }
      }
    case _ where message.contains("Connection refused"):
      haveSessionKey = false // 24 hour lockout
      throw QRZManagerError.lockout
    case _ where message.contains("Username/password incorrect"):
      throw QRZManagerError.invalidCredentials
    default:
      throw QRZManagerError.unknown
    }
  }

  // MARK: - Load files

  public func loadDXCCEntitiesFile() {

    guard let url = Bundle.module.url(forResource: "dxccEntities", withExtension: "csv")  else {
      print("Invalid entity file: ")
      return
      // later make this throw
    }
    do {
      let contents = try String(contentsOf: url, encoding: .utf8)
      let lines = contents.components(separatedBy: "\r\n")

     for callSign in lines{
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

  /// Load the compound call file for testing.
  public func loadCompoundFile() {

    guard let url = Bundle.module.url(forResource: "pskreporter", withExtension: "csv")  else {
      print("Invalid prefix file: ")
      return
      // later make this throw
    }
    do {
      let contents = try String(contentsOf: url)
      let text: [String] = contents.components(separatedBy: "\r\n")
      print("Loaded: \(text.count)")
      for callSign in text{
        callSignList.append(callSign.uppercased())
      }
    } catch {
      // contents could not be loaded
      print("Invalid compound file: ")
    }

//    Task {
//      await hitCache.setReserveCapacity(amount: callSignList.count)
//    }
  }

  // MARK: - Clean Callsign

  /// Clean the call of illegal characters.
  /// - Parameter callSign: String
  /// - Returns: String
  func cleanCallSign(callSign: String) -> String {

    var cleanedCallSign = String(callSign.trimmingCharacters(in: .whitespacesAndNewlines))

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
      cleanedCallSign = String(cleanedCallSign.suffix(cleanedCallSign.count - 1))
    }

    if cleanedCallSign.suffix(1) == "/" {
      cleanedCallSign = String(cleanedCallSign.prefix(cleanedCallSign.count - 1))
    }

    if cleanedCallSign.contains("//") { // EB5KB//P
      cleanedCallSign = cleanedCallSign.replacingOccurrences(of: "//", with: "/")
    }

    if cleanedCallSign.contains("///") { // BU1H8///D
      cleanedCallSign = cleanedCallSign.replacingOccurrences(of: "///", with: "/")
    }

    return cleanedCallSign.uppercased()
  }

  // MARK: - Process Callsign

  /// Process a call sign into its component parts ie: W6OP/V31
  /// - Parameter callSign: String
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

// MARK: - Collect matches and search the main dictionary.

  /// First see if we can find a match for the max prefix of 4 characters.
  /// Then start removing characters from the back until we can find a match.
  /// Once we have a match we will see if we can find a child that is a better match.
  /// - Parameter callStructure: CallStructure
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
    
    _ = searchMainDictionary(structure: callStructure, saveHit: true, matches: &matches)
    hits = buildHit(foundItems: matches, callStructure: callStructure)
  }

  /// Search the CallSignDictionary for a hit with the full call. If it doesn't
  /// hit remove characters from the end until hit or there are no letters left.
  /// - Parameters:
  ///   - callStructure: CallStructure
  ///   - saveHit: Bool
  /// - Returns: String
  func  searchMainDictionary(structure: CallStructure, saveHit: Bool, matches: inout [PrefixData]) -> String
  {
    var callStructure = structure
    let baseCall = callStructure.baseCall
    //var matches = [PrefixData]()
    var mainPrefix = ""

    var firstFourCharacters = (firstLetter: "", secondLetter: "", thirdLetter: "", fourthLetter: "")

    let pattern = determinePatternToUse(callStructure: &callStructure, firstFourCharacters: &firstFourCharacters)

    // first we look in all the "." patterns for calls like KG4AA vs KG4AAA
    var stopCharacterFound = false
    let prefixDataList = matchPattern(pattern: pattern, firstFourCharacters: firstFourCharacters, callPrefix: callStructure.prefix!, stopCharacterFound: &stopCharacterFound)

    switch prefixDataList.count {
    case 0:
      break;
    case 1:
      matches = prefixDataList
    default:
      for prefixData in prefixDataList {
        let primaryMaskList = prefixData.getMaskList(first: firstFourCharacters.firstLetter, second: firstFourCharacters.secondLetter, stopCharacterFound: stopCharacterFound)

        let tempMatches = refineList(baseCall: baseCall!, prefixData: prefixData,primaryMaskList: primaryMaskList)
        // now do a union
        //matches = matches.union(tempMatches)
        matches.append(contentsOf: tempMatches)
      }
    }

    if matches.count > 0 {
      mainPrefix = matchesFound(saveHit: saveHit, matches: matches)
      return mainPrefix
    }

    return mainPrefix
  }

  // MARK: - Determine the pattern and mask to search with.

  /// Determine the pattern to search with.
  /// - Parameters:
  ///   - callStructure: CallStructure
  ///   - firstFourCharacters: (String, String, String, String)
  /// - Returns: String
  func determinePatternToUse(callStructure: inout CallStructure, firstFourCharacters: inout (firstLetter: String, secondLetter: String, thirdLetter: String, fourthLetter: String)) -> String {

    var pattern = ""

    switch callStructure.callStructureType {
    case .prefixCall:
      firstFourCharacters = determineMaskComponents(prefix: callStructure.prefix!)
      pattern = callStructure.buildPattern(candidate: callStructure.prefix)
    case .prefixCallPortable:
      firstFourCharacters = determineMaskComponents(prefix: callStructure.prefix!)
      pattern = callStructure.buildPattern(candidate: callStructure.prefix)
      break
    case .prefixCallText:
      firstFourCharacters = determineMaskComponents(prefix: callStructure.prefix!)
      pattern = callStructure.buildPattern(candidate: callStructure.prefix)
      break
    default:
      callStructure.prefix = callStructure.baseCall
      firstFourCharacters = determineMaskComponents(prefix: callStructure.prefix!)
      pattern = callStructure.buildPattern(candidate: callStructure.baseCall)
      break
    }

    return pattern
  }

  /// Build the tuple to match the mask with.
  /// - Parameter prefix: String
  /// - Returns: (String, String, String, String)
  func determineMaskComponents(prefix: String) -> (String, String, String, String) {
    var firstFourCharacters = (firstLetter: "", secondLetter: "", thirdLetter: "", fourthLetter: "")

    firstFourCharacters.firstLetter = prefix.character(at: 0)!

    if prefix.count > 1
    {
      firstFourCharacters.secondLetter = prefix.character(at: 1)!;
    }

    if prefix.count > 2
    {
      firstFourCharacters.thirdLetter = prefix.character(at: 2)!;
    }

    if prefix.count > 3
    {
      firstFourCharacters.fourthLetter = prefix.character(at: 3)!;
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
  func refineList(baseCall: String, prefixData: PrefixData, primaryMaskList: Set<[[String]]>) -> [PrefixData] {
    var prefixData = prefixData
    var matches = [PrefixData]()
    var rank = 0

    for maskList in primaryMaskList {
      var position = 2
      var isPrevious = true

      let smaller = min(baseCall.count, maskList.count)

      for pos in position..<smaller {
        if maskList[pos].contains(String(baseCall.substring(fromIndex: pos).prefix(1)))  && isPrevious {
          rank = position + 1
        } else {
          isPrevious = false
          break
        }
        position += 1
      }

      if rank == smaller || maskList.count == 2 {
        prefixData.searchRank = rank
        matches.append(prefixData)
      }
    }

    return matches
  }

  /// Build a hit if a match found. Merge multiple hits if requested.
  /// - Parameters:
  ///   - callStructure: CallStructure
  ///   - saveHit: Bool
  ///   - matches: [PrefixData]
  /// - Returns: String
  func matchesFound(saveHit: Bool, matches: [PrefixData]) -> String {

    if saveHit == false {
      return matches.first!.mainPrefix
    } else {
      if !mergeHits || matches.count == 1 {
        return ""
        // moved to collectMatches
        //buildHit(foundItems: matches, callStructure: callStructure)
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
  func matchPattern(pattern: String, firstFourCharacters: (firstLetter: String, secondLetter: String, thirdLetter: String, fourthLetter: String), callPrefix: String, stopCharacterFound: inout Bool) -> [PrefixData] {

    var prefixDataList = [PrefixData]()
    var prefix = callPrefix
    var pattern = pattern.appending(".")

    stopCharacterFound = false

    while pattern.count > 1 {

      guard let query = callSignPatterns[pattern] else {
        pattern.removeLast()
        continue
      }

      for prefixData in query {

        if prefixData.primaryIndexKey.contains(firstFourCharacters.firstLetter) &&
            prefixData.secondaryIndexKey.contains(firstFourCharacters.secondLetter) {

          if pattern.count >= 3 &&
                  !prefixData.tertiaryIndexKey.contains(firstFourCharacters.thirdLetter)  {
                    continue
                  }

          if pattern.count >= 4 &&
                  !prefixData.quatinaryIndexKey.contains(firstFourCharacters.fourthLetter)  {
                    continue
                  }

          var searchRank = 0
          var prefixData = prefixData

          switch pattern[pattern.count - 1] {
          case ".":
            prefix = String(prefix.substring(toIndex: pattern.count - 1))

            if prefixData.setSearchRank(prefix: prefix, excludePortablePrefixes: true, searchRank: &searchRank) {

              prefixData.searchRank = searchRank
              prefixDataList.append(prefixData)
              stopCharacterFound = true

              return prefixDataList
            }
          default:
            prefix = String(prefix.substring(toIndex: pattern.count))

            if prefixData.setSearchRank(prefix: prefix, excludePortablePrefixes: true, searchRank: &searchRank) {

              prefixData.searchRank = searchRank
              // check when there should be multiple hits
              var found = false
              // can compare objects using == func in prefixData struct
              for compare in prefixDataList {
                if compare == prefixData {
                  found = true
                }
              }
              if !found {
                prefixDataList.append(prefixData)
              }
            }
          }
        }
      }
      pattern.removeLast()
    }

    return prefixDataList
  }

  // MARK: - Portable Prefixes

  /// Check if this is a portable prefix ie: AJ3M/BY1RX.
  /// - Parameter callStructure: CallStructure
  /// - Returns: Bool
  func checkForPortablePrefix(callStructure: CallStructure, hit: inout [Hit]) -> Bool {

    var prefix = callStructure.prefix

    if prefix?.suffix(1) != "/" {
      prefix = prefix!  + "/"
    }

    let patternBuilder = callStructure.buildPattern(candidate: prefix!)

    var prefixDataList = getPortablePrefixes(prefix: prefix!, patternBuilder: patternBuilder)

    switch prefixDataList.count {
    case 0:
      break;
    case 1:
      hit = buildHit(foundItems: prefixDataList, callStructure: callStructure)
      return true
    default:
      // only keep the highest ranked prefixData for portable prefixes
      // separates VK0M from VK0H and VP2V and VP2M
      prefixDataList = prefixDataList.sorted(by: {$0.searchRank < $1.searchRank}).reversed()
      let ranked = Int(prefixDataList[0].searchRank)

      var tempPrefixDataList: [PrefixData] = []
      for prefixData in prefixDataList {
        if prefixData.searchRank == ranked {
          tempPrefixDataList.append(prefixData)
        }
      }

      hit = buildHit(foundItems: tempPrefixDataList, callStructure: callStructure)
      return true
    }

    return false
  }

  /// Portable prefixes are prefixes that end with "/"
  /// - Parameters:
  ///   - prefix: String
  ///   - patternBuilder: String
  /// - Returns: [PrefixData]
  func getPortablePrefixes(prefix: String, patternBuilder: String) -> [PrefixData] {
    var prefixDataList = [PrefixData]()
    var tempStorage = [PrefixData]()
    var searchRank = 0

    if let query = portablePrefixes[patternBuilder] {
      // major performance improvement when I moved this from masksExists
      let first = prefix[0]
      let second = prefix[1]
      let third = prefix[2]
      let fourth  = prefix[3]

      for prefixData in query {
        tempStorage.removeAll()

        if prefixData.primaryIndexKey.contains(first) && prefixData.secondaryIndexKey.contains(second) {

          if prefix.count >= 3 && !prefixData.tertiaryIndexKey.contains(third) {
            continue
          }

          // shortcut to next prefixData if no match on fourth character
          if prefix.count >= 4 && !prefixData.quatinaryIndexKey.contains(fourth) {
            continue
          }

          var prefixData = prefixData

          if prefixData.setSearchRank(prefix: prefix, excludePortablePrefixes: false, searchRank: &searchRank) {
            prefixData.searchRank = searchRank
            tempStorage.append(prefixData)
            prefixDataList.append(prefixData)
            // may have to do a union here
          }
        }
      }
    }

    return prefixDataList
  }

  // MARK: - Build Hits

  /// Build the hit from the CallParser lookup and add it to the hit list.
  /// - Parameters:
  ///   - foundItems: [PrefixData]
  ///   - callStructure: CallStructure
  func buildHit(foundItems: [PrefixData], callStructure: CallStructure) -> [Hit] {
    var hitList: [Hit] = []

    let listByRank = foundItems.sorted(by: { (prefixData0: PrefixData, prefixData1: PrefixData) -> Bool in
      return prefixData0.searchRank < prefixData1.searchRank
    })

    for prefixData in listByRank {
      var hit = Hit(callSign: callStructure.fullCall, prefixData: prefixData)
      hit.updateHit(spotId: callStructure.spotId, sequence: callStructure.sequence)
      hitList.append(hit)
      //globalHitList.append(hit)

      Task {  [hit] in
          await hitCache.updateCache(call: callStructure.fullCall, hit: hit)
      }
    }
    return hitList
  }

  // TX4YKP
  /// Build the hit from the QRZ callsign data and add it to the hit list.
  /// - Parameter callSignDictionary: [String: String]
  func buildHit(callSignDictionary: [String: String], spotInformation: (spotId: Int, sequence: Int)) -> Hit {
    var hit = Hit(callSignDictionary: callSignDictionary)
    hit.updateHit(spotId: spotInformation.spotId, sequence: spotInformation.sequence)

    verifyDXCCInformation(hit: &hit)

    let updatedHit = hit
    Task {
      await hitCache.updateCache(call: updatedHit.call, hit: updatedHit)
    }

    return hit
  }

  /// Verify the DXCC information is correct.
  ///
  /// Sometimes for a dxpedition the operators will put in their own country so you have to
  /// check the entity number and get the actual dxpedition location entity.
  /// - Parameter hit: Hit:
  func verifyDXCCInformation(hit: inout Hit) {

    let country = String(dxccEntities[hit.dxcc_entity]!.trimmed)
    let hitCountry = String(hit.country.trimmed)

    if country.localizedCaseInsensitiveCompare(hitCountry) != .orderedSame {
      hit.country = country
      print("\(hitCountry) replaced with \(country): \(hit.call)")
    }
  }

  // MARK: - Call Area Replacement

  /// Check if the call area needs to be replaced and do so if necessary.
  /// If the original call gets a hit, find the MainPrefix and replace
  /// the call area with the new call area. Then do a search with that.
  /// - Parameters:
  ///   - callStructure: CallStructure:
  ///   - hits: [Hit]
  /// - Returns: Bool
  func checkReplaceCallArea(callStructure: CallStructure, hits: inout [Hit]) -> Bool {
    
    let digits = callStructure.baseCall.onlyDigits
    var position = 0
    var matches = [PrefixData]()
    
    // UY0KM/0 - prefix is single digit and same as call
    if callStructure.prefix == String(digits[0]) {

      var callStructure = callStructure
      callStructure.callStructureType = CallStructureType.call
      collectMatches(callStructure: callStructure, hits: &hits)
      return true
    }

    // W6OP/4 will get replace by W4
    let mainPrefix  = searchMainDictionary(structure: callStructure, saveHit: false, matches: &matches)

    if mainPrefix.count > 0 {
      var callStructure = callStructure
      callStructure.prefix = replaceCallArea(mainPrefix: mainPrefix, prefix: callStructure.prefix, position: &position)

      switch callStructure.prefix {

      case "":
        callStructure.callStructureType = CallStructureType.call

      default:
        callStructure.callStructureType = CallStructureType.prefixCall
      }

      collectMatches(callStructure: callStructure, hits: &hits)
      return true;
    }
    
    return false
  }

  /// Replace the call area.
  /// - Parameters:
  ///   - mainPrefix: String:
  ///   - prefix: String:
  ///   - position: Int:
  /// - Returns: String:
  func replaceCallArea(mainPrefix: String, prefix: String,  position: inout Int) -> String{
    
    let oneCharPrefixes: [String] = ["I", "K", "N", "W", "R", "U"]
    let XNUM_SET: [String] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "#", "["]

    switch mainPrefix.count {
    case 1:
      if oneCharPrefixes.contains(mainPrefix[0]){
        // I9MRY/1 - mainPrefix = I --> I1
        position = 2
      } else  if mainPrefix.isAlphabetic {
        // FA3L/6 - mainPrefix is F
        position = 99
        return ""
      }

    case 2:
      if oneCharPrefixes.contains(mainPrefix[0]) && XNUM_SET.contains(mainPrefix[1]) {
        // W6OP/4 - main prefix = W6 --> W4
        position = 2
      } else {
        // AL7NS/4 - main prefix = KL --> KL4
        position = 3
      }

    default:
      if oneCharPrefixes.contains(mainPrefix[0]) && XNUM_SET.contains(mainPrefix[1]){
        position = 2
      }else {
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

} // end struct
