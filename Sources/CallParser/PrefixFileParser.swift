//
//  PrefixFileParser.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation
import Network

// MARK: - CallParser Class ----------------------------------------------------------------------------

@available(OSX 10.14, *)
public class PrefixFileParser: NSObject, ObservableObject {

  var tempMaskList = [String]()
  var callSignPatterns = [String: [PrefixData]]()
  var portablePrefixPatterns = [String: [PrefixData]]()
  var adifs = [Int: PrefixData]()
  var admins  = [String: [PrefixData]]()

  let alphaCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  let alphaNumericCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  let numericCharacters = "0123456789"
  let recordKey = "prefix"
  let errorKey = "Error"

  var prefixData = PrefixData()

  var nodeName: String?
  var currentValue: String?

  // initializer
  public override init() {
    super.init()

    parsePrefixFile()
  }

  /**
   Start parsing the embedded xml file
   - parameters:
   */
  public func parsePrefixFile() {

    // load compound file
    // https://stackoverflow.com/questions/29217554/swift-text-file-to-array-of-strings

    // define the bundle
    guard let url = Bundle.module.url(forResource: "PrefixList", withExtension: "xml")  else {
      print("Invalid prefix file: ")
      return
      // later make this throw
    }

    // define the xmlParser
    guard let parser = XMLParser(contentsOf: url) else {
      print("Parser init failed: ")
      return
      // later make this throw
    }

    parser.delegate = self

    // this is called when the parser has completed parsing the document
    if parser.parse() {
      prefixData.sortMaskList()
    }
  }

  /**
   Expand the masks by expanding the meta characters (@#?) and the groups [1-7]
   */
  func expandMask(element: String) -> [[String]] {
    var primaryMaskList = [[String]]()
    
    let mask = element.trimmingCharacters(in: .whitespacesAndNewlines)
    
    var position = 0
    let offset = mask.startIndex

    // @###
    // <mask>L[2-9O-W]##</mask> @### and @@##
    // <mask>B[#A-LRTYZ]7#</mask> @### and @@##
    // <mask>B[#A-LRTYZ][1-689][#YZ]</mask>
    while position < mask.count {
      // determine if the first character is a "[" [JT][019]
      if mask[mask.index(offset, offsetBy: position)] == "[" {
        let start = mask.index(offset, offsetBy: position)
        let remainder = mask[mask.index(offset, offsetBy: position)..<mask.endIndex]
        let end = remainder.endIndex(of: "]")!
        let substring = mask[start..<end]
        // [JT]
        primaryMaskList.append(expandGroup(group: String(substring)))
        for _ in substring {
          position += 1
        }
      } else {
        let char = mask[mask.index(offset, offsetBy: position)] //mask[position]
        let subItem = expandMetaCharacters(mask: String(char))
        let subArray = subItem.map { String($0) }
        primaryMaskList.append(subArray)
        position += 1
      }
    }
    
    return primaryMaskList
  }

  /**
   Build the pattern from the mask
   7[RT-Y][016-9@]
   KG4@@.
   [AKNW]H7K[./]
   AX9[ABD-KOPQS-VYZ][.ABD-KOPQS-VYZ] @@#@. and @@#@@.
   The [.A-KOPQS-VYZ] mask for the second letter of the suffix means that the call should either end there (no second letter) or be one of the listed letters.
   */
  func buildMaskPattern(primaryMaskList: [[String]]) -> [String] {
    var pattern = ""
    var patternList = [String]()
    
    for maskPart in primaryMaskList {

      switch true {

      case maskPart.allSatisfy({$0.isAlphabetic}):
        pattern += CharacterType.alphabetical.rawValue

      case maskPart.allSatisfy({$0.isInteger}):
        pattern += CharacterType.numeric.rawValue

      case maskPart.allSatisfy({$0.isAlphanumeric()}):
        pattern += CharacterType.alphanumeric.rawValue

      // if all chars are punctuation
      case maskPart.allSatisfy({!$0.isAlphabetic && !$0.isInteger}):
        for part in maskPart {
          switch true {
          case (part == CharacterType.portableIndicator.rawValue ||
                  part == CharacterType.stopIndicator.rawValue):
            patternList = refinePattern(pattern: pattern + part, patternList: patternList)
            break
          default:
            print ("Why am I here?")
            break
          }
        }
        break

      // assume some punctuation
      default:
        for part in maskPart {
          switch true {
          case (part == CharacterType.portableIndicator.rawValue ||
                  part == CharacterType.stopIndicator.rawValue):
            patternList = refinePattern(pattern: pattern + part, patternList: patternList)
            break
          case part.isAlphabetic:
            patternList = refinePattern(pattern: pattern + CharacterType.alphabetical.rawValue, patternList: patternList)
            break
          case part.isInteger:
            patternList = refinePattern(pattern: pattern + CharacterType.numeric.rawValue, patternList: patternList)
            break
          default:
            print ("Why am I here?")
            break
          }
        }

        // CHECK THIS
        return refinePattern(pattern: pattern, patternList: patternList)
      }
    }
    
    return refinePattern(pattern: pattern, patternList: patternList)
  }


  /// Refine the pattern if there are CharacterType.alphanumeric ("?") in it
  /// - Parameter pattern: String
  /// - Returns: [String]
  func refinePattern(pattern: String, patternList: [String]) -> [String] {
    var patternList = patternList

    switch pattern.countInstances(of: CharacterType.alphanumeric.rawValue) {
    case 0:
      if !patternList.contains(pattern) {
        patternList.append(pattern)
      }
    case 1:
      patternList.append(pattern.replacingOccurrences(of: CharacterType.alphanumeric.rawValue, with: CharacterType.alphabetical.rawValue))
      patternList.append(pattern.replacingOccurrences(of: CharacterType.alphanumeric.rawValue, with: CharacterType.numeric.rawValue))
    default:
      // currently only one "[0Q]?" which is invalid prefix (??)
      patternList.append(CharacterType.alphaNumericCombined.rawValue)
      patternList.append(CharacterType.numericAlphaCombined.rawValue)
      break;
    }

    return patternList
  }
  
  /**
   Build the portablePrefix and callSignDictionaries.
   */
  func savePatternList(patternList: [String], prefixData: PrefixData) { //"@@#@."
    
    for pattern in patternList {
      switch pattern.suffix(1) {
      case "/":
        if portablePrefixPatterns.keys.contains(pattern) {
          var newPatternList = portablePrefixPatterns[pattern]
          newPatternList?.append(prefixData)
          portablePrefixPatterns[pattern] = newPatternList
        } else {
          portablePrefixPatterns[pattern] = [PrefixData](arrayLiteral: prefixData)
        }
      default:
        if prefixData.kind != PrefixKind.invalidPrefix {
          if callSignPatterns.keys.contains(pattern) {
            var newPatternList = callSignPatterns[pattern]
            newPatternList?.append(prefixData)
            callSignPatterns[pattern] = newPatternList
          } else {
            callSignPatterns[pattern] = [PrefixData](arrayLiteral: prefixData)
          }
        }
      }
    }
  }

  /**
   Test patterns
   V[H-NZ]9[ABD-KOPQS-VYZ]R
   AX9[ABD-KOPQS-VYZ]R
   AX9[ABD-KOPQS-VYZ][.ABD-KOPQS-VYZ]
   V[H-NZ]9[ABD-KOPQS-VYZ][.ABD-KOPQS-VYZ]
   4U#[A-HJ-TV-Z]
   4U##[A-HJ-TV-Z]
   4U###[A-HJ-TV-Z]
   4U####[A-HJ-TV-Z]
   4[JK][01@]
   4[JK]#/
   4[JK][4-9]
   P[P-Y]0[#B-EG-LN-QU-Y]
   PU1Z[.Z]
   7[RT-Y][016-9@]
   */

  /// Description
  /// - Parameter group: group description
  /// - Returns: description
  func expandGroup(group: String) -> [String]{

    var maskList = [String]()

    let groupArray = group.components(separatedBy: CharacterSet(charactersIn: "[]")).filter({ $0 != ""})

    for group in groupArray {
      var index = 0
      var previous = ""
      var maskCharacters = group.map { String($0) }
      let count = maskCharacters.count
      while (index < count) {
        let maskCharacter = maskCharacters.first
        switch maskCharacter{
        case CharacterType.numeric.rawValue,
             CharacterType.alphabetical.rawValue,
             CharacterType.alphanumeric.rawValue:
          let subItem = expandMetaCharacters(mask: maskCharacter!)
          let subArray = subItem.map { String($0) }
          maskList.append(contentsOf: subArray)
          maskCharacters.removeFirst()
          index += 1
        case "-":
          let first = previous
          let second = maskCharacters.after(CharacterType.dash.rawValue)!
          let subArray = expandRange(first: String(first), second: String(second))
          maskList.append(contentsOf: subArray)
          index += 3
          maskCharacters.removeFirst(2) 
          if maskCharacters.count > 1 {
            maskList.append(maskCharacters.first!)
            previous = maskCharacters.first!
            maskCharacters.removeFirst()
          }
          else {
            if maskCharacters.count != 0 {
              let maskCharacter = maskCharacters.first
              let subItem = expandMetaCharacters(mask: maskCharacter!)
              let subArray = subItem.map { String($0) }
              maskList.append(contentsOf: subArray)
              maskCharacters.removeFirst()
              index += 1
            }
          }
        default:
          maskList.append(maskCharacter!)
          previous = maskCharacters[0]
          maskCharacters.removeFirst()
          index += 1
        }
      }
    }

    return maskList
  }
  
  /**
   Replace meta characters with the strings they represent.
   No point in doing if # exists as strings are very short.
   # = digits, @ = alphas and ? = alphas and numerics
   -parameters:
   -String:
   */
  func expandMetaCharacters(mask: String) -> String {

    var expandedCharacters = mask.replacingOccurrences(of: CharacterType.numeric.rawValue, with: numericCharacters)

    expandedCharacters = expandedCharacters.replacingOccurrences(of: CharacterType.alphabetical.rawValue, with: alphaCharacters)

    expandedCharacters = expandedCharacters.replacingOccurrences(of: CharacterType.alphanumeric.rawValue, with: alphaNumericCharacters)

    return expandedCharacters
  }
  
  /// Expand
  func expandRange(first: String, second: String) -> [String] {

    var expando = [String]()
    
    // 1-5
    if first.isInteger && second.isInteger {
      if let firstInteger = Int(first) {
        if let secondInteger = Int(second) {
          let intArray: [Int] = Array(firstInteger...secondInteger)
          expando = intArray.dropFirst().map { String($0) }
        }
      }
    }
    
    // 0-C
    if first.isInteger && second.isAlphabetic {
      if Int(first) != nil{
        let range: Range<String.Index> = alphaCharacters.range(of: second)!
        let index: Int = alphaCharacters.distance(from: alphaCharacters.startIndex, to: range.lowerBound)

        for item in alphaCharacters[0..<index] {
          expando.append(String(item))
          print (item)
        }

      }
    }
    
    // W-3
    if first.isAlphabetic && second.isInteger {
      if Int(second) != nil{
        let range: Range<String.Index> = alphaCharacters.range(of: first)!
        let index: Int = alphaCharacters.distance(from: alphaCharacters.startIndex, to: range.upperBound)

        for item in alphaCharacters[index..<25] {
          expando.append(String(item))
          print (item)
        }
      }
    }
    
    // A-G
    if first.isAlphabetic && second.isAlphabetic {

      let range: Range<String.Index> = alphaCharacters.range(of: first)!
      let index: Int = alphaCharacters.distance(from: alphaCharacters.startIndex, to: range.lowerBound)
      
      let range2: Range<String.Index> = alphaCharacters.range(of: second)!
      let index2: Int = alphaCharacters.distance(from: alphaCharacters.startIndex, to: range2.upperBound)

      for item in alphaCharacters[index..<index2] {
        expando.append(String(item))
      }
      
      // the first character has already been stored
      expando.remove(at: 0)
    }

    return expando
  }
  
} // end class

//https://stackoverflow.com/questions/45340536/get-next-or-previous-item-to-an-object-in-a-swift-collection-or-array
extension BidirectionalCollection where Iterator.Element: Equatable {
  typealias Element = Self.Iterator.Element

  func after(_ item: Element, loop: Bool = false) -> Element? {
    if let itemIndex = self.firstIndex(of: item) {
      let lastItem: Bool = (index(after:itemIndex) == endIndex)
      if loop && lastItem {
        return self.first
      } else if lastItem {
        return nil
      } else {
        return self[index(after:itemIndex)]
      }
    }
    return nil
  }

  func before(_ item: Element, loop: Bool = false) -> Element? {
    if let itemIndex = self.firstIndex(of: item) {
      let firstItem: Bool = (itemIndex == startIndex)
      if loop && firstItem {
        return self.last
      } else if firstItem {
        return nil
      } else {
        return self[index(before:itemIndex)]
      }
    }
    return nil
  }
}
