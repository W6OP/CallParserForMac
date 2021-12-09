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
  
  public var callSignFlags: [CallSignFlags]

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
}


/// Array of Hits
actor HitList {
  var hitList = [Hit]()

  func setReserveCapacity(amount: Int) {
    hitList.reserveCapacity(amount)
  }

  /// Add a hit to the hitList.
  /// - Parameter hit: Hit
  func updateHitList(hit: Hit) {
    hitList.append(hit)
  }

  /// Retrieve the populated array of Hits.
  /// - Returns: [Hit]
  func retrieveHitList() -> [Hit] {
    return hitList
  }

  /// Clear the hitList for a new run.
  func clearHitList() {
    hitList.removeAll()
  }
}

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
} // end actor

/**
 Parse a call sign and return the country, dxcc, etc.
 */

/// Parse a call sign and return an object describing the country, dxcc, etc.
public class CallLookup: ObservableObject{

  let queue = DispatchQueue(label: "com.w6op.calllookupqueue",
                            qos: .userInitiated, attributes: .concurrent)

  let batchQueue = DispatchQueue(label: "com.w6op.batchlookupqueue",
                                 qos: .userInitiated, attributes: .concurrent)

  // Published item for SwiftUI use.
  @Published public var publishedHitList = [Hit]()

  let logger = Logger(subsystem: "com.w6op.CallParser", category: "CallLookup")

  var hitCache: HitCache
  var hitList: HitList

  var workingHitList = [Hit]()
  var callSignList = [String]()
  var adifs: [Int : PrefixData]
  var prefixList = [PrefixData]()
  var callSignPatterns: [String: [PrefixData]]
  var portablePrefixes: [String: [PrefixData]]
  var mergeHits = false
  
  private let pointsOfInterest = OSLog(subsystem:
                                        Bundle.main.bundleIdentifier!,
                                       category: .pointsOfInterest)

  /// Initialization.
  /// - Parameter prefixFileParser: The parent prefix file parser list to use for searches.
  public init(prefixFileParser: PrefixFileParser) {
    hitCache = HitCache()
    hitList = HitList()

    callSignPatterns = prefixFileParser.callSignPatterns
    portablePrefixes = prefixFileParser.portablePrefixPatterns

    adifs = prefixFileParser.adifs;
  }

  /// Default constructor.
  public init() {
    hitCache = HitCache()
    hitList = HitList()

    callSignPatterns = [String: [PrefixData]]()
    portablePrefixes = [String: [PrefixData]]()

    adifs = [Int : PrefixData]()
  }

  /// Entry point for searching with a call sign.
  /// - Parameter call: The call sign we want to process.
  /// - Returns: Array of Hits.
  public func lookupCall(call: String) -> [Hit] {

    workingHitList = [Hit]()

    Task {
      await hitList.clearHitList()
    }

    Task {
      await MainActor.run {
        publishedHitList = [Hit]()
      }
    }

    processCallSign(callSign: call.uppercased())

    Task {
      let workingHitList2 = await hitList.retrieveHitList()
      await MainActor.run {
        publishedHitList = Array(workingHitList2)
      }
    }

//    DispatchQueue.main.async { [self] in
//      publishedHitList = Array(workingHitList)
//    }

    return workingHitList
  }

  /// Run the batch job with the compound call file.
  /// - Returns: Array of Hits.
  public func runBatchJob()  -> [Hit] {

    Task {
      await hitList.clearHitList()
    }

    Task {
      await MainActor.run {
        publishedHitList = [Hit]()
      }
    }

    return lookupCallBatch(callList: callSignList)
  }

  /// Look up call signs from a collection.
  /// - Parameter callList: array of call signs to process
  /// - Returns: Array of Hits
  func lookupCallBatch(callList: [String]) -> [Hit] {

    workingHitList = [Hit]()
    workingHitList.reserveCapacity(callList.count)

    Task {
      await hitCache.setReserveCapacity(amount: callList.count)
      await hitList.setReserveCapacity(amount: callList.count)
    }
    
    let currentSystemTimeAbsolute = CFAbsoluteTimeGetCurrent()

    let dispatchGroup = DispatchGroup()

    // parallel for loop
    DispatchQueue.global(qos: .userInitiated).sync {
      callList.forEach {_ in dispatchGroup.enter()}
      DispatchQueue.concurrentPerform(iterations: callList.count) { index in
        self.processCallSign(callSign: callList[index])
        dispatchGroup.leave()
      }
      self.onComplete()
    }

    let elapsedTime = CFAbsoluteTimeGetCurrent() - currentSystemTimeAbsolute
    print("Completed in \(elapsedTime) seconds")

    return workingHitList
  }


  /// Completion handler for lookupCallBatch().
  func onComplete() {
    DispatchQueue.main.async { [self] in
      // only display the first 1000 - SwiftUI can't handle a million items in a list
      publishedHitList = Array(workingHitList.prefix(1000))
      print ("Hit List: \(workingHitList.count) -- PrefixDataList: \(publishedHitList.count)")
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
  }
  
  /**
   Process a call sign into its component parts ie: W6OP/V31
   - parameters:
   - call: The call sign to be processed.
   */
  func processCallSign(callSign: String) {

    var cleanedCallSign = callSign.trimmingCharacters(in: .whitespacesAndNewlines)

    // if there are spaces in the call don't process it
    guard !cleanedCallSign.contains(" ") else {
      return
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
        // check if the hit is in the cache
      Task {
        let hit = await hitCache.checkCache(call: callSign)
        if  hit != nil {
          //logger.info("Cache hit for: \(hit!.call)")
          await hitList.updateHitList(hit: hit!)
          //workingHitList.append(hit!)
          return
        }
      }

    let callStructure = CallStructure(callSign: cleanedCallSign, portablePrefixes: portablePrefixes)

    if (callStructure.callStructureType != CallStructureType.invalid) {
        self.collectMatches(callStructure: callStructure)
    }
  }

  /**
   First see if we can find a match for the max prefix of 4 characters.
   Then start removing characters from the back until we can find a match.
   Once we have a match we will see if we can find a child that is a better match.
   - parameters:
   - callSign: The call sign we are working with.
   */
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

  /**

   */

  /// Search the CallSignDictionary for a hit with the full call. If it doesn't
  /// hit remove characters from the end until hit or there are no letters left.
  /// - Parameters:
  ///   - callStructure: the CallStructure to use
  ///   - saveHit: should the hit be saved
  /// - Returns: the main prefix to use
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


  /// Description
  /// - Parameters:
  ///   - callStructure: callStructure description
  ///   - firstFourCharacters: firstFourCharacters description
  /// - Returns: description
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

  /// Description
  /// - Parameter prefix: prefix description
  /// - Returns: description
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

  /// Description
  /// - Parameters:
  ///   - baseCall: String
  ///   - prefixData: PrefixData
  ///   - primaryMaskList: Set<[[String]]>
  /// - Returns: Set<PrefixData>
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

  /// Description
  /// - Parameters:
  ///   - callStructure: callStructure description
  ///   - saveHit: saveHit description
  ///   - matches: matches description
  /// - Returns: description
  func matchesFound(callStructure: CallStructure, saveHit: Bool, matches: [PrefixData]) -> String {

    if saveHit == false {
      return matches.first!.mainPrefix
    } else {
      if !mergeHits || matches.count == 1 {
        buildHit(foundItems: matches, callStructure: callStructure)
      } else {
        // merge multiple hits
        //mergeMultipleHits(matches, callStructure)
      }
    }

    return ""
  }

  /// Description
  /// - Parameters:
  ///   - prefixDataList: prefixDataList description
  ///   - patternBuilder: patternBuilder description
  ///   - firstLetter: firstLetter description
  ///   - callPrefix: callPrefix description
  /// - Returns: description
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

  // AJ3M/BY1RX
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
  ///   - prefix: prefix description
  ///   - patternBuilder: patternBuilder description
  /// - Returns: description
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

  let queue2 = DispatchQueue(label: "thread-safe-obj")

  /**
   Build the hit and add it to the hitlist.
   */
  func buildHit(foundItems: [PrefixData], callStructure: CallStructure) {
    let listByRank = foundItems.sorted(by: { (prefixData0: PrefixData, prefixData1: PrefixData) -> Bool in
      return prefixData0.searchRank < prefixData1.searchRank
    })
    // TX4YKP/R
    for prefixData in listByRank {
      let hit = Hit(callSign: callStructure.fullCall, prefixData: prefixData)

      Task {
        await hitList.updateHitList(hit: hit)
      }
      //workingHitList.append(hit)

      Task {
        if await hitCache.checkCache(call: callStructure.fullCall) == nil {
          await hitCache.updateCache(call: callStructure.fullCall, hit: hit)
        }
      }
    }

    // TODO: QRZ lookup

  }

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
