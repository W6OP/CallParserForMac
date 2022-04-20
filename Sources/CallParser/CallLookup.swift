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

// MARK: - Structs

/// Call sign metadata returned to the calling application.
public struct Hit: Identifiable, Hashable {
  
  public var id = UUID()
  
  public var call = ""                 //call sign as input
  public var kind = PrefixKind.none    //kind
  public var country = ""              //country
  public var province = ""             //province
  public var city = ""                 //city
  public var dxcc_entity = 0           //dxcc_entity
  public var cq_zone = Set<Int>()           //cq_zone
  public var itu_zone = Set<Int>()          //itu_zone
  public var continent = ""            //continent
  public var timeZone = ""             //time_zone
  public var latitude = "0.0"          //lat
  public var longitude = "0.0"         //long
  public var wae = 0
  public var wap = ""
  public var admin1 = ""
  public var admin2 = ""
  public var startDate = ""
  public var endDate = ""
  public var isIota = false // implement
  public var comment = ""
  public var grid = ""
  public var lotw = false
  public var image = "" // future use
  // internal use
  public var sequence = 0
  public var spotId = 0
  
  public var callSignFlags: [CallSignFlags]

  init(callSignDictionary: [String: String]) {
    call = callSignDictionary["call"] ?? ""
    country = callSignDictionary["country"] ?? ""
    latitude = callSignDictionary["lat"] ?? ""
    longitude = callSignDictionary["lon"] ?? ""
    grid = callSignDictionary["grid"] ?? ""
    lotw  = Bool(callSignDictionary["lotw"] ?? "0") ?? false

    kind = PrefixKind.dXCC
    callSignFlags = [CallSignFlags]()
  }

  init(callSign: String, prefixData: PrefixData) {
    call = callSign
    kind = prefixData.kind
    country = prefixData.country
    province = prefixData.province
    city = prefixData.city
    dxcc_entity = prefixData.dxcc_entity
    cq_zone = prefixData.cq_zone
    itu_zone = prefixData.itu_zone
    continent = prefixData.continent
    timeZone = prefixData.timeZone
    latitude = prefixData.latitude
    longitude = prefixData.longitude
    wae = prefixData.wae
    wap = prefixData.wap
    admin1 = prefixData.admin1
    admin2 = prefixData.admin2
    startDate = prefixData.startDate
    endDate = prefixData.endDate
    isIota = prefixData.isIota
    comment = prefixData.comment

    callSignFlags = prefixData.callSignFlags
  }
  mutating func updateHit(spotId: Int, sequence: Int) {
    self.spotId = spotId
    self.sequence = sequence
  }
}

// MARK: - Actors

/// Array of Hits
//actor HitList {
//  var hitList = [Hit]()
//
//  func setReserveCapacity(amount: Int) {
//    hitList.reserveCapacity(amount)
//  }
//
//  /// Add a hit to the hitList.
//  /// - Parameter hit: Hit
//  func updateHitList(hit: Hit) {
//    if !hitList.contains(where: { $0.country == hit.country }) {
//      hitList.append(hit)
//    }
//  }
//// (where: { name in name.id == 1 })
//  /// Retrieve the populated array of Hits.
//  /// - Returns: [Hit]
//  func retrieveHitList() -> [Hit] {
//    return hitList
//  }
//
//  /// Clear the hitList for a new run.
//  func clearHitList() {
//    hitList.removeAll()
//  }
//}

/// Cache hits for future use
actor HitCache {
  var cache = [String: Hit]()

  func setReserveCapacity(amount: Int) {
    cache.reserveCapacity(amount)
  }

  /// Update the hit cache.
  /// - Parameters:
  ///   - call: String
  ///   - hit: Hit
  func updateCache(call: String, hit: Hit) {
    if cache[call] == nil {
      cache[call] = hit
    }
  }

  /// Check if the hit is already in the cache
  /// - Parameter call: call sign to lookup.
  /// - Returns: Hit
  func checkCache(call: String) -> Hit? {
     if cache[call] != nil { return cache[call] }
     return nil
   }

  func clearCache() {
    cache.removeAll()
  }
} // end actor

/**
 Parse a call sign and return the country, dxcc, etc.
 */

// MARK: Class Implementation

/// Parse a call sign and return an object describing the country, dxcc, etc.
public class CallLookup: ObservableObject, QRZManagerDelegate{

  let batchQueue = DispatchQueue(label: "com.w6op.batchlookupqueue",
                                 qos: .userInitiated, attributes: .concurrent)

  /// Published item for SwiftUI use.
  @Published public var publishedHitList = [Hit]()
  // callbacks
  public var didUpdate: (([Hit]?) -> Void)?
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
      qrzManager.requestSessionKey(userId: qrzUserId, password: qrzPassword)
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


  /// Pass logon credentials to QRZ.com
  /// - Parameters:
  ///   - userId: String
  ///   - password: String
  public func logonToQrz(userId: String, password: String) {

    if !haveSessionKey {
      if !userId.isEmpty && !password.isEmpty {
        qrzManager.qrZedManagerDelegate = self
        qrzManager.requestSessionKey(userId: userId, password: password)
      }
    }
  }

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
      // TODO: - FIX THIS - needs real data
      processCallSign(callSign: call, spotInformation: spotInformation)
    }
  }

// MARK: - Lookup Call

  // spotInformation: (spotId: Int, sequence: Int)

  /// Retrieve the hit data for a single call sign.
  /// Clean the callsign of illegal characters. Returned uppercased.
  /// Check the cache and return the hit if it exists.
  /// else -> use the CallParser to get the hit.
  /// This func is for Swift and uses a callback to return a Hit
  /// - Parameter call: String
  public func lookupCall(call: String, spotInformation: (spotId: Int, sequence: Int)) {

    // where I left off - need to test
    Task {
      await MainActor.run {
        publishedHitList.removeAll()
      }
    }

    let callSign = cleanCallSign(callSign: call)

    Task {
      return await withTaskGroup(of: Bool.self) { [unowned self] group in
        for _ in 0..<1 {
          group.addTask {
            return await checkCache(call: callSign)
          }
        }
        // this waits for group.AddTask to complete
        for await item in group {
          if item == true {
            return
          } else {
            do {
            try lookupCallQRZ(callSign: callSign, spotInformation: spotInformation)
            } catch {
              print("QRZ not found use CallParser: \(callSign)")
              processCallSign(callSign: callSign, spotInformation: spotInformation)
            }
          }
        }
      }
    }
  }

  /// Retrieve the hit data for a single call sign.
  /// Clean the callsign of illegal characters. Returned uppercased.
  /// Check the cache and return the hit if it exists.
  /// else -> use the CallParser to get the hit.
  /// This func is for SwiftUI and populates the @Published
  /// variable.
  /// - Parameter call: String
  public func lookupCall(call: String) {

    // where I left off - need to test
    Task {
      await MainActor.run {
        publishedHitList.removeAll()
      }
    }

    let callSign = cleanCallSign(callSign: call)

    Task {
      return await withTaskGroup(of: Bool.self) { [unowned self] group in
        for _ in 0..<1 {
          group.addTask {
            return await checkCache(call: callSign)
          }
        }
        // this waits for group.AddTask to complete
        for await item in group {
          if item == true {
            return
          } else {
            do {
            try lookupCallQRZ(callSign: callSign, spotInformation: (spotId: 0, sequence: 0))
            } catch {
              print("Catch: \(callSign)")
              processCallSign(callSign: callSign, spotInformation: (spotId: 0, sequence: 0))
            }
          }
        }
      }
    }
  }
// TX4YKP

  /// Lookup a call on QRZ.com. Fallback to the CallParser
  /// if nothing found.
  /// - Parameter callSign: String
  func lookupCallQRZ(callSign: String, spotInformation: (spotId: Int, sequence: Int)) throws {

    if haveSessionKey  && !useCallParserOnly {
      Task {
        // TODO: - processCallSign(callSign: callSign) if it throws
        return await withThrowingTaskGroup(of: Void.self) { [unowned self] group in
          for _ in 0..<1 {
            group.addTask {
              return try await qrzManager.requestQRZInformation(call: callSign, spotInformation: spotInformation)
            }
          }
        }
      } // end task
    } else {
      //print("Using CallParser: \(callSign)")
      processCallSign(callSign: callSign, spotInformation: spotInformation)
    }
  }


  // THIS IS WHERE I LEFT OFF - trying to return a hit
  // somewhat synchronously

  /// Retrieve the hit data for a single call sign.
  /// This func is for Swift programs needing a return value.
  /// - Parameter call: String
  /// - Returns: [Hit]
//  public func lookupCallAsync(call: String){
//
//    processCallSign(callSign: call)
//
//
//  }

  /// Run the batch job with the compound call file.
  /// This is only for testing and debugging. Use
  /// lookupCallBatch(callList: String) for production.
  /// - Returns: [Hit]
  public func runBatchJob(clear: Bool) async  -> [Hit] {

    lookupCallBatch(callList: callSignList)

    return [Hit]()
  }

  /// Look up call signs from a collection.
  /// - Parameter callList: [String]
  /// - Returns: [Hits]
  func lookupCallBatch(callList: [String]) {

    let currentSystemTimeAbsolute = CFAbsoluteTimeGetCurrent()

    let dispatchGroup = DispatchGroup()

    // parallel for loop
    DispatchQueue.global(qos: .userInitiated).sync {
      callList.forEach {_ in dispatchGroup.enter()}
      DispatchQueue.concurrentPerform(iterations: callList.count) { index in
        //print("started index=\(index) thread=\(Thread.current)")
        self.processCallSign(callSign: callList[index], spotInformation:
                              (spotId: 1, sequence: index))
        dispatchGroup.leave()
      }
      self.onComplete()
    }

    let elapsedTime = CFAbsoluteTimeGetCurrent() - currentSystemTimeAbsolute
    print("Completed in \(elapsedTime) seconds")
  }

  /// Completion handler for lookupCallBatch().
  func onComplete() {
    Task {
      // only display the first 1000 - SwiftUI can't handle a million items in a list
      //let hits = await (hitList.retrieveHitList()).prefix(1000)
      await MainActor.run {
        //publishedHitList = Array(hits)
      }
    }
  }

  // MARK: - Check Cache

  /// Check if we already have the call data in the cache.
  /// - Parameter call: String
  /// - Returns: Bool
  func checkCache(call: String) async -> Bool {

    // disable cache for testing xCluster
    return false

//    let cacheCheck = Task { () -> Bool in
//      let hit = await hitCache.checkCache(call: call)
//      if hit != nil {
//        await MainActor.run {
//          publishedHitList.removeAll()
//          publishedHitList.append(hit!)
//          didUpdate!(publishedHitList)
//        }
//        // this only returns cacheCheck to program flow
//        return true
//      }
//      // this only returns cacheCheck to program flow
//      return false
//    }
//
//    let result = await cacheCheck.result
//
//    do {
//      if try result.get() {
//        // this returns to calling function
//        return true
//      }
//    } catch {
//      // this returns to calling function
//      return false
//    }
//
//    // this returns to calling function
//    return false
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
  func processCallSign(callSign: String, spotInformation: (spotId: Int, sequence: Int)) {

    var callStructure = CallStructure(callSign: callSign, portablePrefixes: portablePrefixes)
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

    var hits: [Hit] = []

    let listByRank = foundItems.sorted(by: { (prefixData0: PrefixData, prefixData1: PrefixData) -> Bool in
      return prefixData0.searchRank < prefixData1.searchRank
    })

    for prefixData in listByRank {
      var hit = Hit(callSign: callStructure.fullCall, prefixData: prefixData)
      hit.updateHit(spotId: callStructure.spotId, sequence: callStructure.sequence)

      //let updatedHit = hit
      hits.append(hit)

      //let updatedHits = hits

      Task {  [hit] in
        await MainActor.run {
          publishedHitList.append(hit)
          //print(updatedHits.count)
          //didUpdate!(updatedHits)
        }
      }

      Task {  [hit] in
        if await hitCache.checkCache(call: callStructure.fullCall) == nil {
          await hitCache.updateCache(call: callStructure.fullCall, hit: hit)
        }
      }
    }

    Task { [hits] in
      await MainActor.run {
        didUpdate!(hits)
      }
    }

  }

  // TX4YKP
  /// Build the hit from the QRZ callsign data and add it to the hitlist.
  /// - Parameter callSignDictionary: [String: String]
  func buildHit(callSignDictionary: [String: String], spotInformation: (spotId: Int, sequence: Int)) {

    var hits: [Hit] = []
    var hit = Hit(callSignDictionary: callSignDictionary)
    
    hit.updateHit(spotId: spotInformation.spotId, sequence: spotInformation.sequence)

    let updatedHit = hit
    hits.append(updatedHit)
    
    Task {
      //print("Build QRZ hit: \(updatedHit.call)")
      await MainActor.run {
        publishedHitList.append(updatedHit)
      }
    }

    Task {
      if await hitCache.checkCache(call: updatedHit.call) == nil {
        await hitCache.updateCache(call: updatedHit.call, hit: updatedHit)
      }
    }

    didUpdate!(hits)
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
