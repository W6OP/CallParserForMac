//
//  PrefixData.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation
import OSLog

public struct PrefixData: Hashable {
  
  enum CharacterType: String {
    case numeric = "#"
    case alphabetical = "@"
    case alphanumeric = "?"
    case dash = "-"
    case dot = "."
    case slash = "/"
    case empty = ""
  }
  
  private let pointsOfInterest = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: .pointsOfInterest)
  
  public var indexKey = Set<String>()
  public var maskList = Set<[[String]]>() //maskList = new HashSet<List<string[]>>();
  public var tempMaskList = [String]()
  public var rank = 0
 
  var mainPrefix = ""             //label ie: 3B6
  var fullPrefix = ""             // ie: 3B6.3B7
  var kind = PrefixKind.none    //kind
  var country = ""                //country
  var province = ""               //province
  var city = ""                    //city
  var dxcc = 0              //dxcc_entity
  var cq = Set<Int>()           //cq_zone
  var itu = Set<Int>()                    //itu_zone
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
  
  public init () {
   
    callSignFlags = [CallSignFlags]()
  }
  
 
  /**
   
   */
  func getMaskList(first: String, second: String, stopFound: Bool) -> Set<[[String]]> {

    var temp = Set<[[String]]>()

    for item in maskList {
      if stopFound {
        if item[0].contains(first) && item[1].contains(second) && ((item.last?.contains(".")) != nil) {
          temp.insert(item)
        }
      } else {
        if item[0].contains(first) && item[1].contains(second) && ((item.last?.contains(".")) == nil) {
          temp.insert(item)
        }
      }
    }

    return temp
  }
  
  /// If a mask matching the pattern exists return true
  /// -parameters:
  /// call: String
  /// units: [String]
  /// length: Int
  /// returns: Bool
   func maskExists(units: [String], length: Int) -> Bool {
      
      let first = units[0]
      let second = units[1]
      let third = units[2]
      let fourth = units[3]
      let fifth = units[4]
      let sixth = units[5]
      let seventh = units[6]
    
      let portable = "/"
      var maskExists = false
      
//      os_signpost(.begin, log: pointsOfInterest, name: "maskExists start")
//      defer {
//        os_signpost(.end, log: pointsOfInterest, name: "maskExists end")
//      }
      
      for item in maskList {
       
          // use the smaller of the two to search with
          let searchLength = min(length, item.count)
          
          switch searchLength {
          case 2:
            //os_signpost(.event, log: pointsOfInterest, name: "maskExists 2")
            if item[1].contains(second) && item[0].contains(first) {
              if item.last?[0] != portable {
                maskExists = true
              }
            }
            
          case 3:
            if item[2].contains(third) && item[1].contains(second) && item[0].contains(first) {
              if item.last?[0] != portable {
                maskExists =  true
                //os_signpost(.event, log: pointsOfInterest, name: "maskExists 3")
              }
            }
            
          case 4:
            if item[3].contains(fourth) && item[2].contains(third) && item[1].contains(second) &&  item[0].contains(first) {
              if item.last?[0] != portable {
                maskExists =  true
                //os_signpost(.event, log: pointsOfInterest, name: "maskExists 4")
              }
            }
            
          case 5:
            if item[4].contains(fifth) && item[3].contains(fourth) && item[2].contains(third)  && item[1].contains(second)  && item[0].contains(first) {
              if item.last?[0] != portable {
                maskExists =  true
                //os_signpost(.event, log: pointsOfInterest, name: "maskExists 5")
              }
            }
            
          case 6:
            if item[5].contains(sixth) && item[4].contains(fifth) && item[3].contains(fourth)  && item[2].contains(third)  && item[1].contains(second)  && item[0].contains(first) {
              if item.last?[0] != portable {
                maskExists =  true
                //os_signpost(.event, log: pointsOfInterest, name: "maskExists 6")
              }
            }
            
          case 7:
            if item[6].contains(seventh) && item[5].contains(sixth) && item[4].contains(fifth)  && item[3].contains(fourth)  && item[2].contains(third)  && item[1].contains(second) && item[0].contains(first) {
              if item.last?[0] != portable {
                maskExists =  true
                //os_signpost(.event, log: pointsOfInterest, name: "maskExists 7")
              }
            }
            
          default:
            maskExists = false
          }
      }
      
      //os_signpost(.end, log: pointsOfInterest, name: "maskExists end")
      
      if !maskExists {
        _ = 1
      }
      return maskExists
    }
  
  /**
   The index key is a character that can be the first letter of a call.
   This way I can search faster.
   */
  mutating func setPrimaryMaskList(value: [[String]]) {
    
    maskList.insert(value)
    
    for first in value[0] {
      indexKey.insert(first)
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
  
  /**
   Check if a portable mask exists.
   */
  public func portableMaskExists(call: [String]) -> Bool {
    
    let first = call[0]
    let second = call[1]
    let third = call[2]
    let fourth = call[3]
    let fifth = call[4]
    let sixth = call[5]
    
    for item in maskList where item.count == call.count {
     
        switch call.count {
          
        case 2:
          if item[0].contains(String(first)) && item[1].contains(String(second)) {
            return true
          }
          
        case 3:
          if item[0].contains(String(first)) && item[1].contains(String(second)) && item[2].contains(String(third)){
            return true
          }
          
        case 4:
          if item[0].contains(String(first)) && item[1].contains(String(second)) && item[2].contains(String(third)) && item[3].contains(String(fourth)){
            return true
          }
          
        case 5:
          if item[0].contains(String(first)) && item[1].contains(String(second)) && item[2].contains(String(third)) && item[3].contains(String(fourth))  && item[4].contains(String(fifth)){
            return true
          }
          
        case 6:
          if item[0].contains(String(first)) && item[1].contains(String(second)) && item[2].contains(String(third)) && item[3].contains(String(fourth))  && item[4].contains(String(fifth)) && item[5].contains(String(sixth)){
            return true
          }
          
        default:
          break
        }
    }
    
    return false
  }
  /**
   
   
   */
  
  // MARK: Utility Functions ----------------------------------------------------
  
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
