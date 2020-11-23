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
    //let semaphore = DispatchSemaphore(value: 30)
    
    var hitList = [Hit]()
    var callSignList = [String]()
  
    @Published public var prefixDataList = [Hit]()
    var adifs: [Int : PrefixData]
    var prefixList = [PrefixData]()
    var callSignPatterns: [String: [PrefixData]]
    var portablePrefixes: [String: [PrefixData]]
  
    private let pointsOfInterest = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: .pointsOfInterest)

    /**
     Initialization.
     - parameters:
     - prefixList: The parent prefix list to use for searches.
     */
    public init(prefixFileParser: PrefixFileParser) {

       callSignPatterns = prefixFileParser.callSignPatterns;
       adifs = prefixFileParser.adifs;
       portablePrefixes = prefixFileParser.portablePrefixes;

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
      queue.async {
        self.processCallSign(callSign: call.uppercased())
      }
      
      UI{
        self.prefixDataList = Array(self.hitList)
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
    
    UI {
      self.prefixDataList = [Hit]()
      self.prefixDataList.reserveCapacity(callList.count)
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
    
//    UI {
//      self.prefixDataList = Array(self.hitList.prefix(2000)) // .prefix(1000)
//      print ("Hit List: \(self.hitList.count) -- PrifixDataList: \(self.prefixDataList.count)")
//    }
    
    return hitList
  }
  
  func onComplete() {
    UI {
      self.prefixDataList = Array(self.hitList.prefix(2000)) // .prefix(1000)
      print ("Hit List: \(self.hitList.count) -- PrifixDataList: \(self.prefixDataList.count)")
    }
  }

  /**
   Load the compound call file for testing.
   - parameters:
   */
  public func loadCompoundFile() {
    //var batch = [String]()
    
    // guard let url = Bundle.module.url(forResource: "pskreporter", withExtension: "csv")  else {
    //let bundle = Bundle(identifier: "com.w6op.CallParser")
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
      print("Invalid compund file: ")
    }
  }
  
 
    /**
     Process a call sign into its component parts ie: W6OP/V31
     - parameters:
     - call: The call sign to be processed.
     */
    func processCallSign(callSign: String) {
      
//      os_signpost(.begin, log: pointsOfInterest, name: "processCallSign start")
//      defer {
//        os_signpost(.end, log: pointsOfInterest, name: "processCallSign end")
//      }
      
      var cleanedCall = ""// = callSign
      
      // if there are spaces in the call don't process it
      cleanedCall = callSign.replacingOccurrences(of: " ", with: "")
        if cleanedCall.count != callSign.count {
          return
        }
      
      // strip leading or trailing "/"  /W6OP/
      if callSign.prefix(1) == "/" {
        cleanedCall = String(callSign.suffix(callSign.count - 1))
      }
      
      if callSign.suffix(1) == "/" {
        cleanedCall = String(cleanedCall.prefix(cleanedCall.count - 1))
      }
      
      if callSign.contains("//") { // EB5KB//P
        cleanedCall = callSign.replacingOccurrences(of: "//", with: "/")
      }
      
      if callSign.contains("///") { // BU1H8///D
        cleanedCall = callSign.replacingOccurrences(of: "///", with: "/")
      }
      
      let callStructure = CallStructure(callSign: cleanedCall, portablePrefixes: portablePrefixes);

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
    
//    if callStructure.baseCall == "B1Z" {
//      _ = 1
//    }
//    os_signpost(.begin, log: pointsOfInterest, name: "collectMatches start")
//    defer {
//      os_signpost(.end, log: pointsOfInterest, name: "collectMatches end")
//    }
    
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
    
    if searchMainDictionary(callStructure: callStructure, saveHit: true).result == true
    {
        return;
    }
}
  
  /**
   Search the CallSignDictionary for a hit with the full call. If it doesn't
   hit remove characters from the end until hit or there are no letters fleft.
   */
  func  searchMainDictionary(callStructure: CallStructure, saveHit: Bool) -> (mainPrefix: String, result: Bool)
  {
    //let prefix = callStructure.prefix
    
    var pattern: String
    var searchBy = SearchBy.prefix
    
    if String(callStructure.callStructureType.rawValue.first!) == "C" {
      pattern = callStructure.buildPattern(candidate: callStructure.baseCall)
      searchBy = SearchBy.call
    } else {
      pattern = callStructure.buildPattern(candidate: callStructure.prefix)
    }
    
    return performSearch(candidate: pattern, callStructure: callStructure, searchBy: searchBy, saveHit: saveHit)
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
    
//    os_signpost(.begin, log: pointsOfInterest, name: "performSearch start")
//       defer {
//         os_signpost(.end, log: pointsOfInterest, name: "performSearch end")
//       }
    
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
    
    // major performance improvement when I moved this from masksExists
//    let second = searchTerm[1]
//    let third = searchTerm[2]
//    let fourth  = searchTerm[3]
//    let fifth = searchTerm[4]
//    let sixth = searchTerm[5]
//    let seventh = searchTerm[6]
    
    let units = [first, searchTerm[1], searchTerm[2], searchTerm[3], searchTerm[4], searchTerm[5], searchTerm[6]]
    
    while (pattern.count > 1)
    {
      if let valuesExists = callSignPatterns[pattern] {
        // slower even though it makes the loop much shorter
      //?.all(where: {$0.indexKey.contains(firstLetter)}) {
        
        temp = Set<PrefixData>()

        for prefixData in valuesExists {
          if prefixData.indexKey.contains(first) {
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
    
//    os_signpost(.begin, log: pointsOfInterest, name: "refineHits start")
//    defer {
//      os_signpost(.end, log: pointsOfInterest, name: "refineHits end")
//    }
    
    
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
          let primaryMaskList = prefixData.getMaskList(first: String(firstLetter), second: nextLetter, stopFound: false)
          
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
              var data = prefixData
              data.rank = rank
              foundItems.insert(data)
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
          buildHit(foundItems: found, prefix: baseCall!, fullCall: callStructure.fullCall)
          return (mainPrefix: "", result: true)
        }
      }

      return (mainPrefix: "", result: false)
  }
  
  /**
   Portable prefixes are prefixes that end with "/"
   */
  func checkForPortablePrefix(callStructure: CallStructure) -> Bool {
    
    let prefix = callStructure.prefix + "/"
    var list = [PrefixData]()
    var temp = [PrefixData]()
    let first = prefix[0]
    let pattern = callStructure.pattern //.buildPattern(candidate: prefix)
    
    if let query = portablePrefixes[pattern] {
      
//      os_signpost(.begin, log: pointsOfInterest, name: "checkForPortablePrefix start")
//      defer {
//        os_signpost(.end, log: pointsOfInterest, name: "checkForPortablePrefix end")
//      }
      
      // major performance improvement when I moved this from masksExists
      let second = prefix[1]
      let third = prefix[2]
      let fourth  = prefix[3]
      let fifth = prefix[4]
      let sixth = prefix[5]
      
      let units = [first, second, third, fourth, fifth, sixth]
      
      for prefixData in query {
        temp.removeAll()
        if prefixData.indexKey.contains(first) {
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
      buildHit(foundItems: list, prefix: prefix, fullCall: callStructure.fullCall);
        return true;
    }
    
    return false
  }
  
  /**
   Build the hit and add it to the hitlist.
   */
  func buildHit(foundItems: [PrefixData], prefix: String, fullCall: String) {
    
    let sortedItems = foundItems.sorted(by: { (prefixData0: PrefixData, prefixData1: PrefixData) -> Bool in
      return prefixData0.rank < prefixData1.rank
    })
    
//    os_signpost(.begin, log: pointsOfInterest, name: "buildHit start")
//    defer {
//      os_signpost(.end, log: pointsOfInterest, name: "buildHit end")
//    }
    
    for prefixData in sortedItems {
      let hit = Hit(callSign: fullCall, prefixData: prefixData)
      queue.async(flags: .barrier) {
        self.hitList.append(hit)
      }
    }
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
     
//      os_signpost(.begin, log: pointsOfInterest, name: "single digit checkReplaceCallArea")
//      defer {
//        os_signpost(.end, log: pointsOfInterest, name: "single digit checkReplaceCallArea")
//      }
      
      var callStructure = callStructure
      callStructure.callStructureType = CallStructureType.call
      collectMatches(callStructure: callStructure);
      return true
    }
    
//    os_signpost(.begin, log: pointsOfInterest, name: "searchMainDictionary checkReplaceCallArea")
//         defer {
//           os_signpost(.end, log: pointsOfInterest, name: "searchMainDictionary checkReplaceCallArea")
//         }
    
    // W6OP/4 will get replace by W4
      let found  = searchMainDictionary(callStructure: callStructure, saveHit: false)
      if found.result {
        var callStructure = callStructure
        callStructure.prefix = replaceCallArea(mainPrefix: found.mainPrefix, prefix: callStructure.prefix, position: &position)
        
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
