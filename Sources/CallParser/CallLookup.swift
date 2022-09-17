//
//  CallLookup.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation
import Combine
import os
import SwiftUI
import CoreLocation


actor PublishedHits: ObservableObject {
  var hits: [Hit] = []

  func addHit(hit: Hit) {
    hits.append(hit)
  }

  func clear() {
    hits.removeAll()
  }

  func getCount() -> Int {
    return hits.count
  }

}
/**
 Parse a call sign and return the country, dxcc, etc.
 */

// MARK: Class Implementation

/// Parse a call sign and return an object describing the country, dxcc, etc.
public class CallLookup: QRZManagerDelegate{

  let batchQueue = DispatchQueue(label: "com.w6op.batchlookupqueue",
                                 qos: .userInitiated, attributes: .concurrent)

  /// Published item for SwiftUI use.
  public var globalHitList = [Hit]()
  // callbacks
  //public var didUpdate: (([Hit]?) -> Void)?
  public var didGetSessionKey: (((state: Bool, message: String)?) -> Void)?

  let logger = Logger(subsystem: "com.w6op.CallParser", category: "CallLookup")

  /// Actors
  var hitCache: HitCache

  var qrzManager = QRZManager()
  var haveSessionKey = false
  public var useCallParserOnly = false

  /// local vars
  var callSignList = [String]()
  var adifs: [Int : PrefixData]
  var prefixList = [PrefixData]()
  var callSignPatterns: [String: [PrefixData]]
  var portablePrefixes: [String: [PrefixData]]
  var mergeHits = false
  
  private let pointsOfInterest = OSLog(subsystem:
                                        Bundle.main.bundleIdentifier!,
                                       category: .pointsOfInterest)

  // MARK: - Initializers

  /// Initialization with a QRZ user name and password.
  /// - Parameter prefixFileParser: PrefixFileParser
  public init(prefixFileParser: PrefixFileParser, qrzUserId: String, qrzPassword: String) {
    hitCache = HitCache()

    callSignPatterns = prefixFileParser.callSignPatterns
    portablePrefixes = prefixFileParser.portablePrefixPatterns
    adifs = prefixFileParser.adifs

    if !qrzUserId.isEmpty && !qrzPassword.isEmpty {
      qrzManager.qrZedManagerDelegate = self
      qrzManager.qrzUserName = qrzUserId
      qrzManager.qrzPassword = qrzPassword
      // TODO: NEED TO RE-IMPLEMENT THIS
      //qrzManager.requestSessionKey(userId: qrzUserId, password: qrzPassword)
    }
  }

  /// Initialization without a QRZ user name and password.
  /// - Parameter prefixFileParser: PrefixFileParser
  public init(prefixFileParser: PrefixFileParser) {
    hitCache = HitCache()

    callSignPatterns = prefixFileParser.callSignPatterns
    portablePrefixes = prefixFileParser.portablePrefixPatterns
    adifs = prefixFileParser.adifs
  }

  /// Default constructor.
  public init() {
    hitCache = HitCache()

    callSignPatterns = [String: [PrefixData]]()
    portablePrefixes = [String: [PrefixData]]()
    adifs = [Int : PrefixData]()
  }

  // MARK: QRZManager Protocol Implementation


// Works
//  public func logonToQrz(userId: String, password: String, completion: @escaping (Bool) -> Void) {
//    if !haveSessionKey {
//      if !userId.isEmpty && !password.isEmpty {
//        qrzManager.qrZedManagerDelegate = self
//        qrzManager.requestSessionKey(userId: userId, password: password)
//      }
//    }
//    print("session key request complete: \(haveSessionKey)")
//    completion(haveSessionKey)
//  }

  public func logonToQrz(userId: String, password: String, completion: @escaping (Bool) -> Void) {
    if !haveSessionKey {
      if !userId.isEmpty && !password.isEmpty {
        Task {
          await getSessionKey(userId: userId, password: password)
        }
      }
    }

    completion(haveSessionKey)
  }


  /*
   <?xml version=\"1.0\" encoding=\"utf-8\" ?>\n<QRZDatabase version=\"1.34\" xmlns=\"http://xmldata.qrz.com\">\n<Session>\n<Error>Not found: DK2IE</Error>\n<Key>f3b353df045f2ada690ae2725096df09</Key>\n<Count>9772923</Count>\n<SubExp>Thu Dec 29 00:00:00 2022</SubExp>\n<GMTime>Mon Dec 27 16:35:29 2021</GMTime>\n<Remark>cpu: 0.018s</Remark>\n</Session>\n</QRZDatabase>\n
   */

  public func getSessionKey(userId: String, password: String) async {

    let data = try! await qrzManager.requestSessionKey(userId: userId, password: password)
      self.qrzManager.parseSessionData(data: data, call: userId, completion: { sessionDictionary in

        if sessionDictionary["Key"] != nil && !sessionDictionary["Key"]!.isEmpty {
          print("Received session key")
          self.haveSessionKey = true
          self.qrzManager.sessionKey = sessionDictionary["Key"]
          self.qrzManager.isSessionKeyValid = true
        } else {
          print("session key request failed: \(sessionDictionary)")
          self.haveSessionKey = false
        }
      })
  }


  /// Pass logon credentials to QRZ.com
  /// - Parameters:
  ///   - userId: String
  ///   - password: String
  //  public func logonToQrz(userId: String, password: String) {
  //
  //    if !haveSessionKey {
  //      if !userId.isEmpty && !password.isEmpty {
  //        qrzManager.qrZedManagerDelegate = self
  //        qrzManager.requestSessionKey(userId: userId, password: password)
  //      }
  //    }
  //  }

  /// Delegate to receive session key notification.
  /// - Parameters:
  ///   - qrzManager: QRZManager
  ///   - messageKey: QRZManagerMessage
  ///   - doHaveSessionKey: Bool
  func qrzManagerDidGetSessionKey(_ qrzManager: QRZManager,
                                  messageKey: QRZManagerMessage,
                                  doHaveSessionKey: Bool) {

    haveSessionKey = doHaveSessionKey
    let message: String = messageKey.rawValue
    didGetSessionKey!((state: doHaveSessionKey, message: message))
  }


  /// Delegate to receive notification of call sign data.
  /// - Parameters:
  ///   - qrzManager: QRZManager
  ///   - messageKey: QRZManagerMessage
  func qrzManagerDidGetCallSignData(_ qrzManager: QRZManager,
                                    messageKey: QRZManagerMessage,
                                    call: String, spotInformation: (spotId: Int, sequence: Int)) {

    let callSignDictionary: [String: String] = qrzManager.callSignDictionary

    // this could be "Error"
    if callSignDictionary["call"] != nil && !callSignDictionary["call"]!.isEmpty {
      buildHit(callSignDictionary: callSignDictionary, spotInformation: spotInformation)
    } else {
      processCallSign(call: call, spotInformation: spotInformation)
    }
  }

  // MARK: - Lookup Call

  // TX4YKP

  // MARK: NEW STUFF --------------------------------------------------------------------------

  public func clearCache() {
    Task {
      await hitCache.clearCache()
    }
  }

  /// Retrieve the hit data for a single call sign.
  ///
  /// Clean the callsign of illegal characters. Returned uppercased.
  /// Check the cache and return the hit if it exists.
  /// else -> use the CallParser to get the hit.
  /// - Parameters:
  ///   - call: String: call sign.
  ///   - completion: Completion: array of Hits.
  public func lookupCall(call: String, completion: @escaping ([Hit]) -> Void) {
    let callSignUpper = cleanCallSign(callSign: call)
    let spotInformation = (spotId: 0, sequence: 0)
    globalHitList.removeAll()

    Task {
      if let hit = await hitCache.checkCache(call: callSignUpper) {
        print("Cache hit: \(callSignUpper)")
        globalHitList.append(hit)
        completion(globalHitList)
        return
      }

      //old try lookupCallQRZ(callSign: callSignUpper, spotInformation: (spotId: 0, sequence: 0))
      if haveSessionKey  && !useCallParserOnly {
        await lookupQrzCall(call: callSignUpper, spotInformation: spotInformation)
      } else {
        processCallSign(call: callSignUpper, spotInformation: spotInformation)
      }

      completion(globalHitList)
    }
  }


  public func lookupQrzCall (call: String, spotInformation: (spotId: Int, sequence: Int)) async {
    print("2a")
      let data = try! await qrzManager.requestQRZInformation(call: call)
      print("2b")
      self.qrzManager.parseReceivedData(data: data, call: call, spotInformation: spotInformation, completion: { callSignDictionary, spotInformation in
        print("3")
        if callSignDictionary["call"] != nil && !callSignDictionary["call"]!.isEmpty {
          print("4a")
          self.buildHit(callSignDictionary: callSignDictionary, spotInformation: spotInformation)
        } else {
          print("4b")
          self.processCallSign(call: call, spotInformation: spotInformation)
        }
      })

    print("2d")
  }

  /// Retrieve the hit data for a pair of call signs.
  ///
  /// Clean the callsign of illegal characters. Returned uppercased.
  /// Check the cache and return the hit if it exists.
  /// else -> use the CallParser to get the hit.
  /// - Parameters:
  ///   - spotter: String: the spotter station call sign.
  ///   - dx: String: the dx station call sign.
  ///   - completion: Completion: array of Hits.
  public func lookupCallPair(spotter: String, dx: String, completion: @escaping ([Hit]) -> Void) {

    let spotterCall = cleanCallSign(callSign: spotter)
    let dxCall = cleanCallSign(callSign: dx)
    globalHitList.removeAll()

    Task {
      var spotInformation = (spotId: 0, sequence: 0)
      do {
        if let spotterHit = await hitCache.checkCache(call: spotterCall) {
          print("Cache hit: \(spotterCall)")
          globalHitList.append(spotterHit)
        } else {
          async let _ = await lookupQrzCall(call: spotterCall, spotInformation: spotInformation)
        }

        if let dxHit = await hitCache.checkCache(call: dxCall) {
          print("Cache hit: \(dxCall)")
          globalHitList.append(dxHit)
        } else {
          spotInformation.sequence = 1
          async let _ = await lookupQrzCall(call: dxCall, spotInformation: spotInformation)
        }
      } catch {
        // this could allow dupes if second try failed, should check cache here too but if true, ignore
        spotInformation.sequence = 0
        async let _ = processCallSign(call: spotterCall, spotInformation: spotInformation)

        spotInformation.sequence = 1
        async let _ = processCallSign(call: dxCall, spotInformation: spotInformation)
      }
      completion(globalHitList)
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
  ///   - completion: Completion: array of Hits.
  public func lookupCallPair(spotter: (call: String, sequence: Int), dx: (call: String, sequence: Int), completion: @escaping ([Hit]) -> Void) {

    let spotterCall = cleanCallSign(callSign: spotter.call)
    let dxCall = cleanCallSign(callSign: dx.call)
    globalHitList.removeAll()

    // TODO: cache needs sequence number updated

    Task {
      do {
        if let spotterHit = await hitCache.checkCache(call: spotterCall) {
          print("Cache hit: \(spotterCall)")
          
          globalHitList.append(spotterHit)
        } else {
          async let _ = try lookupCallQRZ(callSign: spotterCall, spotInformation: (spotId: 0, sequence: spotter.sequence))
        }

        if let dxHit = await hitCache.checkCache(call: dxCall) {
          print("Cache hit: \(dxCall)")
          globalHitList.append(dxHit)
        } else {
          async let _ = try lookupCallQRZ(callSign: dxCall, spotInformation: (spotId: 0, sequence: dx.sequence))
        }
      } catch {
        // TODO: this could allow dupes if second try failed, should check cache here too but if true, ignore
        async let _ = processCallSign(call: spotterCall, spotInformation: (spotId: 0, sequence: spotter.sequence))
        async let _ = processCallSign(call: dxCall, spotInformation: (spotId: 0, sequence: dx.sequence))
      }
      completion(globalHitList)
    }
  }
  // ---------------------------------------------------------------------


//    func qrzLookup(callSign: String, spotInformation: (spotId: Int, sequence: Int)) {
//
//      lookupCallQRZ(callSign: callSign, spotInformation: spotInformation) { hits in
//        print("Hits: \(hits)")
//        self.globalHitList.append(contentsOf: hits)
//      }
//  }
//
//  public func lookupCallQRZ(callSign: String, spotInformation: (spotId: Int, sequence: Int), completion: @escaping ([Hit]) -> Void) {
//
//    Task {
//      do {
//        try lookupCallQRZ(callSign: callSign,
//                          spotInformation: (spotId: spotInformation.spotId,
//                                            sequence: spotInformation.sequence))
//
//      } catch {
//        print("Catch: \(callSign)")
//        processCallSign(callSign: callSign,
//                        spotInformation: (spotId: spotInformation.spotId,
//                                          sequence: spotInformation.sequence))
//      }
//      print("global: \(globalHitList)")
//      completion(globalHitList)
//    }
//  }

  /// CURRENT FUNCTION
  /// Lookup a call on QRZ.com. Fallback to the CallParser
  /// if nothing found.
  /// - Parameter callSign: String
  func lookupCallQRZ(callSign: String, spotInformation: (spotId: Int, sequence: Int)) throws {
    if haveSessionKey  && !useCallParserOnly {
      Task {
//        try await qrzManager.requestQRZInformation(call: callSign, spotInformation: spotInformation)
      }
    } else {
      processCallSign(call: callSign, spotInformation: spotInformation)
    }
  }

//  func lookupCallQRZ(callSign: String, spotInformation: (spotId: Int, sequence: Int)) throws {
//    if haveSessionKey  && !useCallParserOnly {
//      Task {
//        // TODO: - processCallSign(callSign: callSign) if it throws
//        return await withThrowingTaskGroup(of: Void.self) { [unowned self] group in
//          for _ in 0..<1 {
//            group.addTask { [self] in
//              return try await qrzManager.requestQRZInformation(call: callSign, spotInformation: spotInformation)
//            }
//          }
//        }
//      } // end task
//    } else {
//      processCallSign(callSign: callSign, spotInformation: spotInformation)
//    }
//  }

  //  public func logonToQrz(userId: String, password: String, completion: @escaping (Bool) -> Void) {
  //    if !haveSessionKey {
  //      if !userId.isEmpty && !password.isEmpty {
  //        qrzManager.qrZedManagerDelegate = self
  //        qrzManager.requestSessionKey(userId: userId, password: password)
  //      }
  //    }
  //    print("session key request complete")
  //    completion(haveSessionKey)
  //  }


  // MARK: - Load file

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

    Task {
      await hitCache.setReserveCapacity(amount: callSignList.count)
    }
  }

  // MARK: - Clean Callsign

  /// Clean the call of illegal characters.
  /// - Parameter callSign: String
  /// - Returns: String
  func cleanCallSign(callSign: String) -> String {

    var cleanedCallSign = callSign.trimmingCharacters(in: .whitespacesAndNewlines)

    // if there are spaces in the call don't process it
    guard !cleanedCallSign.contains(" ") else {
      // SHOULD THROW
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
  func processCallSign(call: String, spotInformation: (spotId: Int, sequence: Int)) {
    var callStructure = CallStructure(callSign: call, portablePrefixes: portablePrefixes)
    callStructure.spotId = spotInformation.spotId
    callStructure.sequence = spotInformation.sequence

    if (callStructure.callStructureType != CallStructureType.invalid) {
        self.collectMatches(callStructure: callStructure)
    }
  }

// MARK: - Collect matches and search the main dictionary.

  /// First see if we can find a match for the max prefix of 4 characters.
  /// Then start removing characters from the back until we can find a match.
  /// Once we have a match we will see if we can find a child that is a better match.
  /// - Parameter callStructure: CallStructure
  func collectMatches(callStructure: CallStructure) {
    let callStructureType = callStructure.callStructureType
    
    switch (callStructureType)
    {
    case CallStructureType.callPrefix:
      if checkForPortablePrefix(callStructure: callStructure) { return }

    case CallStructureType.prefixCall:
      if checkForPortablePrefix(callStructure: callStructure) { return }

    case CallStructureType.callPortablePrefix:
      if checkForPortablePrefix(callStructure: callStructure) { return }

    case CallStructureType.callPrefixPortable:
      if checkForPortablePrefix(callStructure: callStructure) { return }

    case CallStructureType.prefixCallPortable:
      if checkForPortablePrefix(callStructure: callStructure) { return }

    case CallStructureType.prefixCallText:
      if checkForPortablePrefix(callStructure: callStructure) { return }

    case CallStructureType.callDigit:
      if checkReplaceCallArea(callStructure: callStructure) { return }
      
    default:
      break
    }
    
    _ = searchMainDictionary(structure: callStructure, saveHit: true)
  }

  /// Search the CallSignDictionary for a hit with the full call. If it doesn't
  /// hit remove characters from the end until hit or there are no letters left.
  /// - Parameters:
  ///   - callStructure: CallStructure
  ///   - saveHit: Bool
  /// - Returns: String
  func  searchMainDictionary(structure: CallStructure, saveHit: Bool) -> String
  {
    var callStructure = structure
    let baseCall = callStructure.baseCall
    var matches = [PrefixData]()
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
      mainPrefix = matchesFound(callStructure: callStructure, saveHit: saveHit, matches: matches)
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
        //var a = baseCall.substring(fromIndex: pos) && isPrevious
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
  func matchesFound(callStructure: CallStructure, saveHit: Bool, matches: [PrefixData]) -> String {

    if saveHit == false {
      return matches.first!.mainPrefix
    } else {
      if !mergeHits || matches.count == 1 {
        buildHit(foundItems: matches, callStructure: callStructure)
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
            prefix = prefix.substring(toIndex: pattern.count - 1)

            if prefixData.setSearchRank(prefix: prefix, excludePortablePrefixes: true, searchRank: &searchRank) {

              prefixData.searchRank = searchRank
              prefixDataList.append(prefixData)
              stopCharacterFound = true

              return prefixDataList
            }
          default:
            prefix = prefix.substring(toIndex: pattern.count)

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
  func checkForPortablePrefix(callStructure: CallStructure) -> Bool {

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
      buildHit(foundItems: prefixDataList, callStructure: callStructure)
      return true
    default:
      // only keep the highest ranked prefixData for portable prefixes
      // separates VK0M from VK0H and VP2V and VP2M
      prefixDataList = prefixDataList.sorted(by: {$0.searchRank < $1.searchRank}).reversed()
      let ranked = Int(prefixDataList[0].searchRank)
      prefixDataList.removeAll()

      for prefixData in prefixDataList {
        if prefixData.searchRank == ranked {
          prefixDataList.append(prefixData)
        }
      }

      buildHit(foundItems: prefixDataList, callStructure: callStructure)
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

  /// Build the hit from the CallParser lookup and add it to the hitlist.
  /// - Parameters:
  ///   - foundItems: [PrefixData]
  ///   - callStructure: CallStructure
  func buildHit(foundItems: [PrefixData], callStructure: CallStructure) {
    let listByRank = foundItems.sorted(by: { (prefixData0: PrefixData, prefixData1: PrefixData) -> Bool in
      return prefixData0.searchRank < prefixData1.searchRank
    })

    for prefixData in listByRank {
      var hit = Hit(callSign: callStructure.fullCall, prefixData: prefixData)
      hit.updateHit(spotId: callStructure.spotId, sequence: callStructure.sequence)

      globalHitList.append(hit)

      Task {  [hit] in
          await hitCache.updateCache(call: callStructure.fullCall, hit: hit)
      }
    }
  }

  // TX4YKP
  /// Build the hit from the QRZ callsign data and add it to the hit list.
  /// - Parameter callSignDictionary: [String: String]
  func buildHit(callSignDictionary: [String: String], spotInformation: (spotId: Int, sequence: Int)) {

    var hit = Hit(callSignDictionary: callSignDictionary)
    hit.updateHit(spotId: spotInformation.spotId, sequence: spotInformation.sequence)

    print("qrz hit found: \(hit)")
    globalHitList.append(hit)

    let updatedHit = hit
    Task {
        await hitCache.updateCache(call: updatedHit.call, hit: updatedHit)
    }
  }

  // MARK: - Call Area Replacement

  /**
   Check if the call area needs to be replaced and do so if necessary.
   If the original call gets a hit, find the MainPrefix and replace
   the call area with the new call area. Then do a search with that.
   */
  func checkReplaceCallArea(callStructure: CallStructure) -> Bool {
    
    let digits = callStructure.baseCall.onlyDigits
    var position = 0
    
    // UY0KM/0 - prefix is single digit and same as call
    if callStructure.prefix == String(digits[0]) {

      var callStructure = callStructure
      callStructure.callStructureType = CallStructureType.call
      collectMatches(callStructure: callStructure);
      return true
    }

    // W6OP/4 will get replace by W4
    let mainPrefix  = searchMainDictionary(structure: callStructure, saveHit: false)
    if mainPrefix.count > 0 {
      var callStructure = callStructure
      callStructure.prefix = replaceCallArea(mainPrefix: mainPrefix, prefix: callStructure.prefix, position: &position)

      switch callStructure.prefix {

      case "":
        callStructure.callStructureType = CallStructureType.call

      default:
        callStructure.callStructureType = CallStructureType.prefixCall
      }

      collectMatches(callStructure: callStructure)
      return true;
    }
    
    return false
  }
  
  
  /**
   
   */
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
  
  /**
   
   */


} // end struct
