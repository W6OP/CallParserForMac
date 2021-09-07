//
//  CallLookup.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation
import Combine
import OSLog

public struct Hit: Identifiable, Hashable {
  
    public var id = UUID()
  
    public var call = ""                   //call sign as input
    public var kind = PrefixKind.none    //kind
    public var country = ""                //country
    public var province = ""               //province
    public var city = ""                   //city
    public var dxcc_entity = 0            //dxcc_entity
    public var cq = Set<Int>()                    //cq_zone
    public var itu = Set<Int>()                   //itu_zone
    public var continent = ""              //continent
    public var timeZone = ""               //time_zone
    public var latitude = "0.0"            //lat
    public var longitude = "0.0"           //long
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
        dxcc_entity = prefixData.dxcc
        cq = prefixData.cq
        itu = prefixData.itu
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

/**
 Look up the data on a call sign.
 */
public class CallLookup: ObservableObject{
    
  let queue = DispatchQueue(label: "com.w6op.calllookupqueue", qos: .userInitiated, attributes: .concurrent)
  let batchQueue = DispatchQueue(label: "com.w6op.batchlookupqueue", qos: .userInitiated, attributes: .concurrent)

  @Published public var hitList = [Hit]()

    var callSignList = [String]()
    var adifs: [Int : PrefixData]
    var prefixList = [PrefixData]()
    var callSignPatterns: [String: [PrefixData]]
    var portablePrefixes: [String: [PrefixData]]
    var mergeHits = false
  
    private let pointsOfInterest = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: .pointsOfInterest)

    /**
     Initialization.
     - parameters:
     - prefixList: The parent prefix list to use for searches.
     */
    public init(prefixFileParser: PrefixFileParser) {

       callSignPatterns = prefixFileParser.callSignPatterns;
       adifs = prefixFileParser.adifs;
       portablePrefixes = prefixFileParser.portablePrefixPatterns;

    }
    
  public init() {
    callSignPatterns = [String: [PrefixData]]()
    adifs = [Int : PrefixData]()
    portablePrefixes = [String: [PrefixData]]()
  }
  
    /**
     Entry point for searching with a call sign.
     - parameters:
     - callSign: The call sign we want to process.
     */
  public func lookupCall(call: String) -> [Hit] {

    hitList = [Hit]()

    processCallSign(callSign: call.uppercased())

    DispatchQueue.main.async {
      self.hitList = Array(self.hitList)
    }

    return hitList
  }
  
  /**
   Run the batch job with the compound call file.
   - parameters:
   */
   public func runBatchJob()  -> [Hit] {
       return lookupCallBatch(callList: callSignList)
   }
     
  
  /**
   Look up call signs from a collection.
   */
  func lookupCallBatch(callList: [String]) -> [Hit] {
    
    hitList = [Hit]()
    hitList.reserveCapacity(callList.count)
    
    DispatchQueue.main.async {
      self.hitList = [Hit]()
      self.hitList.reserveCapacity(callList.count)
    }
    
    let start = CFAbsoluteTimeGetCurrent()
    
   
    let dispatchGroup = DispatchGroup()

    DispatchQueue.global(qos: .userInitiated).sync {
       callList.forEach {_ in dispatchGroup.enter()}
          DispatchQueue.concurrentPerform(iterations: callList.count) { index in
              self.processCallSign(callSign: callList[index])
              dispatchGroup.leave()
          }
          self.onComplete()
    }
    
    
    let diff = CFAbsoluteTimeGetCurrent() - start
    print("Took \(diff) seconds")

    return hitList
  }
  
  func onComplete() {
    DispatchQueue.main.async {
      self.hitList = Array(self.hitList.prefix(2000)) // .prefix(1000)
      print ("Hit List: \(self.hitList.count) -- PrifixDataList: \(self.hitList.count)")
    }
  }

  /**
   Load the compound call file for testing.
   - parameters:
   */
  public func loadCompoundFile() {

    guard let url = Bundle.module.url(forResource: "pskreporter", withExtension: "csv")  else { //bundle!.url(forResource: "pskreporter", withExtension: "csv") else {
      print("Invalid prefix file: ")
      return
      // later make this throw
    }
    do {
      let contents = try String(contentsOf: url)
      let text: [String] = contents.components(separatedBy: "\r\n")
      print("Loaded: \(text.count)")
      for callSign in text{
        //print(callSign)
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

      var callSign = callSign.trimmingCharacters(in: .whitespacesAndNewlines)

      // if there are spaces in the call don't process it
      if callSign.contains(" ") {
        return
      }

      // strip leading or trailing "/"  /W6OP/
      if callSign.prefix(1) == "/" {
        callSign = String(callSign.suffix(callSign.count - 1))
      }
      
      if callSign.suffix(1) == "/" {
        callSign = String(callSign.prefix(callSign.count - 1))
      }
      
      if callSign.contains("//") { // EB5KB//P
        callSign = callSign.replacingOccurrences(of: "//", with: "/")
      }
      
      if callSign.contains("///") { // BU1H8///D
        callSign = callSign.replacingOccurrences(of: "///", with: "/")
      }

      // TODO: create cache if batch lookup
      // ...
      
      let callStructure = CallStructure(callSign: callSign, portablePrefixes: portablePrefixes);

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
    
    switch (callStructureType) // GT3UCQ/P
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
    
     _ = searchMainDictionary(callStructure: callStructure, saveHit: true)
}
  // OEM3SGU/3
  /**
   Search the CallSignDictionary for a hit with the full call. If it doesn't
   hit remove characters from the end until hit or there are no letters left.
   */
  func  searchMainDictionary(callStructure: CallStructure, saveHit: Bool) -> String
  {
    let baseCall = callStructure.baseCall
    var prefix = callStructure.prefix
    var matches = [PrefixData]()
    var pattern: String
    var mainPrefix = ""

    var firstFourCharacters = (firstLetter: "", nextLetter: "", thirdLetter: "", fourthLetter: "")

    switch callStructure.callStructureType {
    case .prefixCall:
      firstFourCharacters = determineMaskComponents(prefix: prefix!)
      // TODO: buildPattern needs to be checked for correctness
      pattern = callStructure.buildPattern(candidate: callStructure.prefix)
    case .prefixCallPortable:
      firstFourCharacters = determineMaskComponents(prefix: prefix!)
      pattern = callStructure.buildPattern(candidate: callStructure.prefix)
      break
    case .prefixCallText:
      firstFourCharacters = determineMaskComponents(prefix: prefix!)
      pattern = callStructure.buildPattern(candidate: callStructure.prefix)
      break
    default:
      prefix = baseCall
      firstFourCharacters = determineMaskComponents(prefix: prefix!)
      //firstFourCharacters.firstLetter = (baseCall?.character(at: 0))!
      //firstFourCharacters.nextLetter = (baseCall?.character(at: 1))!
      pattern = callStructure.buildPattern(candidate: callStructure.baseCall)
    break
    }

    // first we look in all the "." patterns for calls like KG4AA vs KG4AAA
//    let stopCharacterFound = matchPattern(prefixDataList: prefixDataList, patternBuilder: patternBuilder, firstLetter: firstAndSecond.firstLetter, callPrefix: prefix!)

    var stopCharacterFound = false
    let prefixDataList = matchPattern(pattern: pattern, firstFourCharacters: firstFourCharacters, callPrefix: prefix!, stopCharacterFound: &stopCharacterFound)

      switch prefixDataList.count {
      case 0:
        break;
      case 1:
        matches = prefixDataList
      default:
        for prefixData in prefixDataList {
          let primaryMaskList = prefixData.getMaskList(first: firstFourCharacters.firstLetter, second: firstFourCharacters.nextLetter, stopCharacterFound: stopCharacterFound)

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
  /// - Parameter prefix: prefix description
  /// - Returns: description
  func determineMaskComponents(prefix: String) -> (String, String, String, String) {
    var firstFourCharacters = (firstLetter: "", nextLetter: "", thirdLetter: "", fourthLetter: "")

    firstFourCharacters.firstLetter = prefix.character(at: 0)!

    if prefix.count > 1
     {
      firstFourCharacters.nextLetter = prefix.character(at: 1)!;
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
  ///   - prefixDataList: prefixDataList description
  ///   - patternBuilder: patternBuilder description
  ///   - firstLetter: firstLetter description
  ///   - callPrefix: callPrefix description
  /// - Returns: description
  func matchPattern(pattern: String, firstFourCharacters: (firstLetter: String, nextLetter: String, thirdLetter: String, fourthLetter: String), callPrefix: String, stopCharacterFound: inout Bool) -> [PrefixData] {

    var prefixDataList = [PrefixData]()
    var prefix = callPrefix
    var pattern = pattern.appending(".")

    stopCharacterFound = false

    while pattern.count > 1 {
      if callSignPatterns[pattern] != nil {
        let query = callSignPatterns[pattern]
        for prefixData in query! {
          if prefixData.comment == "This is the one" {
            _ = 1
          }
          var prefixData = prefixData

          //print(prefixData.maskList)

          if prefixData.primaryIndexKey.contains(firstFourCharacters.firstLetter) && prefixData.secondaryIndexKey.contains(firstFourCharacters.nextLetter) {

            if pattern.count >= 3 && !prefixData.tertiaryIndexKey.contains(firstFourCharacters.thirdLetter) {
              continue
            }

            if pattern.count >= 4 && !prefixData.quatinaryIndexKey.contains(firstFourCharacters.fourthLetter) {
              continue
            }

            var searchRank = 0

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
                for pd in prefixDataList {
                  if pd == prefixData {
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
      }
      pattern.removeLast()
    }

    return prefixDataList
  }

  /**
    first we look in all the "." patterns for calls like KG4AA vs KG4AAA
    pass in the callStructure and a flag to use prefix or baseCall
    */
  func performSearch(candidate: String, callStructure: CallStructure, searchBy: SearchBy, saveHit: Bool) -> (mainPrefix: String, result: Bool) {
    
    var pattern = candidate + "."
    var temp = Set<PrefixData>()
    var list = Set<PrefixData>()
    var first: String
    var searchTerm = ""

    switch searchBy {
    case .call:
      let baseCall = callStructure.baseCall
      searchTerm = baseCall!
      first = baseCall![0]
    default:
      let prefix = callStructure.prefix
      first = prefix![0]
      searchTerm = prefix!
      if prefix!.count > 1 {
      }
    }
    
    let units = [first, searchTerm[1], searchTerm[2], searchTerm[3], searchTerm[4], searchTerm[5], searchTerm[6]]
    
    while (pattern.count > 1)
    {
      if let valuesExists = callSignPatterns[pattern] {
        // slower even though it makes the loop much shorter
      //?.all(where: {$0.indexKey.contains(firstLetter)}) {
        
        temp = Set<PrefixData>()

        for prefixData in valuesExists {
          if prefixData.primaryIndexKey.contains(first) {
            if pattern.last == "." {
              if prefixData.maskExists(units: units, length: pattern.count - 1) {
                temp.insert(prefixData)
                break
              }
            } else {
              if prefixData.maskExists(units: units, length: pattern.count) {
                temp.insert(prefixData)
                break
              }
            }
          }
        }
      }

      if temp.count != 0 {
        list = list.union(temp)
        break
      }

      pattern.removeLast()
    }


    return refineHits(list: list, callStructure: callStructure, searchBy: searchBy, saveHit: saveHit)
  }
  
  /**
  now we have a list of posibilities // HG5ACZ/P
  */
  func refineHits(list: Set<PrefixData>, callStructure: CallStructure, searchBy: SearchBy, saveHit: Bool) -> (mainPrefix: String, result: Bool) {
     
    var firstLetter: String
    var nextLetter: String = ""
    let baseCall = callStructure.baseCall
    var foundItems =  Set<PrefixData>()

    switch searchBy {
    case .call:
      
      firstLetter = baseCall![0]
      nextLetter = String(baseCall![1])
    default:
      let prefix = callStructure.prefix
      firstLetter = prefix![0]
      if prefix!.count > 1 {
         nextLetter = String(prefix![1])
      }
    }
    
    switch list.count {
      case 0:
        return (mainPrefix: "", result: false)
      case 1:
        foundItems = list
      default:
        for prefixData in list {
          var rank = 0
          var previous = true
          let primaryMaskList = prefixData.getMaskList(first: String(firstLetter), second: nextLetter, stopCharacterFound: false)
          
          for maskList in primaryMaskList {
            var position = 2
            previous = true
            
            let length = min(maskList.count, baseCall!.count)
            for index in 2...length {
              let anotherLetter = baseCall![index]
              if maskList[position].contains(String(anotherLetter)) && previous {
                rank = position + 1
              } else {
                previous = false
                break
              }
              position += 1
            }
            
            if rank == length || maskList.count == 2 {
              var prefixData = prefixData
              prefixData.searchRank = rank
              foundItems.insert(prefixData)
            }
          }
        }
      }
      
      if foundItems.count > 0 {
        if !saveHit {
          let items = Array(foundItems)
          return (mainPrefix: items[0].mainPrefix, result: true)
        } else {
          let found = Array(foundItems)
          buildHit(foundItems: found, callStructure: callStructure)
          return (mainPrefix: "", result: true)
        }
      }

      return (mainPrefix: "", result: false)
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
  

  /**
   Portable prefixes are prefixes that end with "/"
   */
  func checkForPortablePrefixEx(callStructure: CallStructure) -> Bool {
    
    let prefix = callStructure.prefix + "/"
    var list = [PrefixData]()
    var temp = [PrefixData]()
    let first = prefix[0]
    let pattern = callStructure.pattern //.buildPattern(candidate: prefix)
    
    if let query = portablePrefixes[pattern] {

      // major performance improvement when I moved this from masksExists
      let second = prefix[1]
      let third = prefix[2]
      let fourth  = prefix[3]
      let fifth = prefix[4]
      let sixth = prefix[5]
      
      let units = [first, second, third, fourth, fifth, sixth]
      
      for prefixData in query {
        temp.removeAll()
        if prefixData.primaryIndexKey.contains(first) {
          if prefixData.portableMaskExists(call: units) {
            temp.append(prefixData)
          }
        }
        
        if temp.count != 0 {
          list = Array(Set(list + temp))
          break
        }
      }
    }
    
    if list.count > 0
    {
      buildHit(foundItems: list, callStructure: callStructure);
        return true;
    }
    
    return false
  }
  
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
      //  hit.CallSignFlags.UnionWith(callStructure.CallSignFlags)
        hitList.append(hit)
    }

    // TODO: add to cache - QRZ lookup


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
    // change to mainPrfix (string)
      let mainPrefix  = searchMainDictionary(callStructure: callStructure, saveHit: false)
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
