//
//  PrefixData.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation
import OSLog

public struct PrefixData: Hashable, Equatable {
  
  private let pointsOfInterest = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: .pointsOfInterest)
  
  public var primaryIndexKey = Set<String>()
  public var secondaryIndexKey = Set<String>()
  public var tertiaryIndexKey = Set<String>()
  public var quatinaryIndexKey = Set<String>()
  public var maskList = Set<[[String]]>() //maskList = new HashSet<List<string[]>>();
  private var sortedMaskList = [[[String]]]()
  public var tempMaskList = [String]()
  public var searchRank = 0
 
  var mainPrefix = ""             //label ie: 3B6
  var fullPrefix = ""             // ie: 3B6.3B7
  var kind = PrefixKind.none    //kind
  var country = ""                //country
  var province = ""               //province
  var city = ""                    //city
  var dxcc_entity = 0              //dxcc_entity
  var cq_zone = Set<Int>()           //cq_zone
  var itu_zone = Set<Int>()                    //itu_zone
  var continent = ""              //continent
  var timeZone = ""               //time_zone
  var latitude = "0.0"            //lat
  var longitude = "0.0"           //long
  
  var callSignFlags: [CallSignFlags]
  
  var wae = 0
  var wap = ""
  var admin1 = ""
  var admin2 = ""
  var startDate = ""
  var endDate = ""
  var isIota = false // implement
  var comment = ""
  
  var id = 1
  // for debugging
  var maskCount = 0
  
  let alphabet: [Character] = ["A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z"]
  let numbers: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

  //let portableIndicator = "/"
  //let stopIndicator = "."
  
  public init () {
   
    callSignFlags = [CallSignFlags]()
  }
  

  public mutating func sortMaskList() {
    // descending
    sortedMaskList = maskList.sorted(by: {$0.count < $1.count}).reversed()
  }
  /**
   
   */
  func getMaskList(first: String, second: String, stopCharacterFound: Bool) -> Set<[[String]]> {

    var componentList = Set<[[String]]>()

    for maskItem in sortedMaskList {
      if stopCharacterFound {
        if maskItem[0].contains(first) && maskItem[1].contains(second) && ((maskItem.last?.contains(CharacterType.stopIndicator.rawValue)) != nil) {
          componentList.insert(maskItem)
        }
      } else {

        if (maskItem[maskItem.count - 1].count == 1) {
          if maskItem[0].contains(first) && maskItem[1].contains(second) && ((!maskItem.last!.contains(CharacterType.stopIndicator.rawValue))) {
            componentList.insert(maskItem)
          }
        }
        else
        {
          if maskItem[0].contains(first) && maskItem[1].contains(second) {
            componentList.insert(maskItem)
          }
        }
      }
    }

    return componentList
  }

  /// The index key is a character that can be the first letter of a call.
  /// This way I can search faster.
  /// - Parameter value: [[String]]
  mutating func setPrimaryMaskList(value: [[String]]) {
    
    maskList.insert(value)
    
    for first in value[0] {
      primaryIndexKey.insert(first)
    }

    setSecondaryMaskList(value: value)

    sortMaskList()
  }


  /// The index key is a character that can be the second letter of a call.
  /// - Parameter value: [[String]]
  mutating func setSecondaryMaskList(value: [[String]]) {

    for first in value[1] {
      secondaryIndexKey.insert(first)
    }

    if value.count > 2 {
      setTertiaryMaskList(value: value)
    }
  }


  /// The index key is a character that can be the third letter of a call.
  /// - Parameter value: [[String]]
  mutating func setTertiaryMaskList(value: [[String]]) {

    for first in value[2] {
      tertiaryIndexKey.insert(first)
    }

    if value.count > 3 {
      setQuatinaryMaskList(value: value)
    }
  }


  /// The index key is a character that can be the fourth letter of a call.
  /// - Parameter value: [[String]]
  mutating func setQuatinaryMaskList(value: [[String]]) {

    for first in value[3] {
      quatinaryIndexKey.insert(first)
    }
  }

  /**
   Parse the FullPrefix to get the MainPrefix
   - parameters:
   - fullPrefix: fullPrefix value.
   */
  mutating func setMainPrefix(fullPrefix: String) {
    if let index = fullPrefix.range(of: ".")?.upperBound {
      mainPrefix = String(fullPrefix[index...])
    } else {
      mainPrefix = fullPrefix
    }
  }
  
  /**
   If this is a top level set the kind and adif flags.
   - parameters:
   - prefixKind: PrefixKind
   */
  mutating func setPrefixKind(prefixKind: PrefixKind) {
    
    self.kind = prefixKind
    
    if prefixKind == PrefixKind.dXCC {
      province = ""
    }
  }
  
  /**
   Some entities have multiple CQ and ITU zones
   - parameters:
   - zones: String
   */
  mutating func buildZoneList(zones: String) -> Set<Int> {
    
    let zoneArrayString = zones.split(separator: ",")
    
    return Set(zoneArrayString.map { Int($0)! })
  }

  /// Description
  /// - Parameters:
  ///   - prefix: prefix description
  ///   - excludePortablePrefixes: excludePortablePrefixes description
  ///   - searchRank: searchRank description
  /// - Returns: description
  mutating func setSearchRank(prefix: String, excludePortablePrefixes: Bool, searchRank: inout Int) -> Bool {
    searchRank = 1

    let prefixLength = prefix.count
    let first = prefix[0]
    let second = prefix[1]
    var third = ""
    var fourth = ""
    var fifth = ""

    if prefixLength > 2
    {
        third = prefix[2]
    }

    if prefixLength > 3
    {
        fourth = prefix[3]
    }

    if prefixLength > 4
    {
        fifth = prefix[4]
    }

    for maskItem in sortedMaskList {
      let maxLength = min(prefixLength, maskItem.count)

      // short circuit if first character fails
      if !maskItem[0].contains(String(first)) {
        continue
      }

      // if exclude portable prefixes and the last character is a "/"
      // this needs checking
      if excludePortablePrefixes && maskItem[maskItem.count - 1].contains(CharacterType.portableIndicator.rawValue) {
        continue
      }

      switch maxLength {
      case 2:
        if maskItem[1].contains(second) {
          searchRank = 2
          return true
        }
      case 3:
        if maskItem[1].contains(second)  &&
            maskItem[2].contains(third) {
          searchRank = 3
          return true
        }
      case 4:
        if maskItem[1].contains(second)  &&
            maskItem[2].contains(third) &&
            maskItem[3].contains(fourth) {
          searchRank = 4
          return true
        }
      case 5:
        if maskItem[1].contains(second)  &&
            maskItem[2].contains(third) &&
            maskItem[3].contains(fourth) &&
            maskItem[4].contains(fifth) {
          searchRank = 5
          return true
        }
      case 6:
        if maskItem[1].contains(second)  &&
            maskItem[2].contains(third) &&
            maskItem[3].contains(fourth) &&
            maskItem[4].contains(fifth) &&
            maskItem[5].contains(prefix.character(at: 5)!) {
          searchRank = 6
          return true
        }
      case 7:
        if maskItem[1].contains(second)  &&
            maskItem[2].contains(third) &&
            maskItem[3].contains(fourth) &&
            maskItem[4].contains(fifth) &&
            maskItem[5].contains(prefix.character(at: 5)!) &&
            maskItem[6].contains(prefix.character(at: 6)!) {
          searchRank = 7
          return true
        }
      default:
        break
      }
    }

    return false
  }
  
  // MARK: Utility Functions ----------------------------------------------------

  // https://stackoverflow.com/questions/30105272/compare-two-instances-of-an-object-in-swift/30105471
  public static func == (lhs: PrefixData, rhs: PrefixData) -> Bool{
          return
              lhs.dxcc_entity == rhs.dxcc_entity &&
              lhs.province == rhs.province &&
              lhs.mainPrefix == rhs.mainPrefix &&
              lhs.city == rhs.city &&
              lhs.fullPrefix == rhs.fullPrefix &&
              lhs.country == rhs.country
      }

  //https://stackoverflow.com/questions/38838133/how-to-increment-string-in-swift
  /**
   Get the character index or number index from alphabets and numbers arrays.
   - parameters:
   - character: character to be processed.
   */
  func getCharFromArr(index i:Int) -> Character {
    if(i < alphabet.count){
      return alphabet[i]
    }else{
      print("wrong index")
      return ""
    }
  }
  
  func getNumberFromArr(index i:Int) -> Character {
    if(i < numbers.count){
      return numbers[i]
    }else{
      print("wrong index")
      return ""
    }
  }
  
  func getCharacterIndex(char: String) -> Int {
    
    for item in alphabet {
      if char == String(item) {
        return alphabet.firstIndex(of: Character(char)) ?? 99
      }
    }
    return 99
  }
  
  func getNumberIndex(char: String) -> Int {
    
    for item in numbers {
      if char == String(item) {
        return numbers.firstIndex(of: Character(char)) ?? 99
      }
    }
    return 99
  }
} // end PrefixData
