//
//  PrefixFileParser.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation
import Network

/** utility functions to run a UI or background thread
 // USAGE:
 BG() {
 everything in here will execute in the background
 }
 https://www.electrollama.net/blog/2017/1/6/updating-ui-from-background-threads-simple-threading-in-swift-3-for-ios
 */
func BG(_ block: @escaping ()->Void) {
  DispatchQueue.global(qos: .utility).async(execute: block)
}

/**  USAGE:
 UI() {
 everything in here will execute on the main thread
 }
 */
func UI(_ block: @escaping ()->Void) {
    DispatchQueue.main.async(execute: block)
}



// MARK: - CallParser Class ----------------------------------------------------------------------------

@available(OSX 10.14, *)
public class PrefixFileParser: NSObject, ObservableObject {
    
   var tempMaskList = [String]()
    //public var prefixList = [PrefixData]()
    // pattern is key
  // rename to prefixPatterns
    public var callSignPatterns = [String: [PrefixData]]()
    // pattern is key
    public var portablePrefixes = [String: [PrefixData]]()
    public var adifs = [Int: PrefixData]()
    public var admins  = [String: [PrefixData]]()
    var prefixData = PrefixData()
    
    var recordKey = "prefix"
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
        
        recordKey = "prefix"
        
      // load compound file
      // https://stackoverflow.com/questions/29217554/swift-text-file-to-array-of-strings
      
      // define the bundle
      //let settingsURL = Bundle.module.url(forResource: "PrefixList", withExtension: "xml")
        //let bundle = Bundle(identifier: "com.w6op.CallParser")
        guard let url = Bundle.module.url(forResource: "PrefixList", withExtension: "xml")  else { //bundle!.url(forResource: "PrefixList", withExtension: "xml")
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
//            for i in 0..<self.prefixList.count {
//
//            }
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
   KG4@@.
   [AKNW]H7K[./]
   AX9[ABD-KOPQS-VYZ][.ABD-KOPQS-VYZ] @@#@. and @@#@@.
   The [.A-KOPQS-VYZ] mask for the second letter of the suffix means that the call should either end there (no second letter) or be one of the listed letters.
   */
  func buildMaskPattern(primaryMaskList: [[String]]) {
    var pattern = ""
    var patternList = [String]()
    
    for maskPart in primaryMaskList {
      
      switch true {
        
      case maskPart.allSatisfy({$0.isInteger}):
        pattern += "#"
        
      case maskPart.allSatisfy({$0.isAlphabetic}):
        pattern += "@"
        
        case maskPart.allSatisfy({$0.isAlphanumeric()}):
        pattern += "?"
        
      case maskPart[0] == "/":
        pattern += "/"
        
      case maskPart[0] == ".":
        pattern += "."
        if maskPart.count > 1 {
          patternList.append(pattern)
          patternList.append(pattern.replacingOccurrences(of: ".", with: "@."))
          savePatternList(patternList: patternList)
          return
        }
        
      case maskPart[0] == "?":
        // for debugging
        print("Hit ? - buildPatternEx")
        
      default:
        // should never default
        print("should never default - hit default - buildPattern Line 213 \(maskPart)")
        return
      }
    }
    
    if pattern.contains("?") {
      // # @  - only one (invalid prefix) has two ?  -- @# @@
      patternList.append(pattern.replacingOccurrences(of: "?", with: "#"))
      patternList.append(pattern.replacingOccurrences(of: "?", with: "@"))
      savePatternList(patternList: patternList)
      return
    }
    
    patternList.append(pattern)
    savePatternList(patternList: patternList)
  }
  
  /**
   Build the portablePrefix and callSignDictionaries.
   */
  func savePatternList(patternList: [String]) { //"@@#@."
    
    for pattern in patternList {
      switch pattern.suffix(1) {
      case "/":
        if var valueExists = portablePrefixes[pattern] {
          valueExists.append(prefixData)
          portablePrefixes[pattern] = valueExists
        } else {
          portablePrefixes[pattern] = [PrefixData](arrayLiteral: prefixData)
        }
      default:
        if prefixData.kind != PrefixKind.invalidPrefix {
          if var valueExists = callSignPatterns[pattern] {
            valueExists.append(prefixData)
            callSignPatterns[pattern] = valueExists
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
   */
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
        case "#", "@", "?":
          let subItem = expandMetaCharacters(mask: maskCharacter!) // group
          let subArray = subItem.map { String($0) }
          maskList.append(contentsOf: subArray)
          maskCharacters.removeFirst()
          index += 1
        case "-":
          let first = previous
          let second = maskCharacters.after("-")!
          let subArray = expandRange(first: String(first), second: String(second))
          maskList.append(contentsOf: subArray)
          index += 3
          maskCharacters.removeFirst(2) 
          if maskCharacters.count > 1 {
            maskList.append(maskCharacters.first!)
            previous = maskCharacters.first!
            maskCharacters.removeFirst()
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

  func expandGroupOld(group: String) -> [String]{

    var maskList = [String]()

    //let group2 = "L[1-9O-W]#[DE]"

    let groupArray = group.components(separatedBy: CharacterSet(charactersIn: "[]")).filter({ $0 != ""})

    for maskGroup in groupArray {
      var index = 0
      var previous = ""
      // array of String[L] : String[1, -, 9, O, -, W] : String[#] : String[D,E]
      var maskCharacters = maskGroup.map { String($0) }
      let count = maskCharacters.count
      while (index < count) { // subElementArray.count
        let maskCharacter = maskCharacters[0]
        switch maskCharacter{
        case "#", "@", "?":
          let subItem = expandMetaCharacters(mask: maskGroup)
          let subArray = subItem.map { String($0) }
          maskList.append(contentsOf: subArray)
          index += 1
        case "-":
          let first = previous //subElementArray.before("-")!
          let second = maskCharacters.after("-")!
          let subArray = expandRange(first: String(first), second: String(second))
          maskList.append(contentsOf: subArray)
          index += 3
          maskCharacters.removeFirst(2) // remove first two chars !!!
          if maskCharacters.count > 1 {
            maskList.append(maskCharacters[0])
            previous = maskCharacters[0]
            maskCharacters.removeFirst()
          }
        default:
          //maskList.append(contentsOf: [String](arrayLiteral: maskGroup))
          maskList.append(maskCharacter)
          previous = maskCharacters[0]
          maskCharacters.removeFirst()
          index += 1
        }
      }
    }

    return maskList
  }
 
  /**
   L[1-9O-W]#[DE]
   take individual characters until [ is hit
   get everything between [ and ]
   take first character until - is hit

   */
//  func expandGroup(group: String) -> [String]{
//
//    var maskList = [String]()
//
//    let groupArray = group.components(separatedBy: CharacterSet(charactersIn: "[]")).filter({ $0 != ""})
//
//    for element in groupArray {
//      var index = 0
//      let subElementArray = element.map { String($0) }
//
//      while (index < subElementArray.count) {
//        let subElement = subElementArray[index]
//        switch subElement{
//        case "#", "@", "?":
//          let subItem = expandMetaCharacters(mask: element)
//          let subArray = subItem.map { String($0) }
//          maskList.append(contentsOf: subArray)
//        case "-":
//          let first = subElementArray.before("-")!
//          let second = subElementArray.after("-")!
//          let subArray = expandRange(first: String(first), second: String(second))
//          maskList.append(contentsOf: subArray)
//          index += 1
//          break
//        default:
//          maskList.append(contentsOf: [String](arrayLiteral: element))
//        }
//        index += 1
//      }
//    }
//
//    return maskList
//  }
  
  /**
   Replace meta characters with the strings they represent.
   No point in doing if # exists as strings are very short.
   # = digits, @ = alphas and ? = alphas and numerics
   -parameters:
   -String:
   */
  func expandMetaCharacters(mask: String) -> String {

    var expandedCharacters: String
    
    expandedCharacters = mask.replacingOccurrences(of: "#", with: "0123456789")
    expandedCharacters = expandedCharacters.replacingOccurrences(of: "@", with: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    expandedCharacters = expandedCharacters.replacingOccurrences(of: "?", with: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
   
    return expandedCharacters
  }
  
  /// Expand
   func expandRange(first: String, second: String) -> [String] {
    
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
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
    
    // 0-C - NOT TESTED
    if first.isInteger && second.isAlphabetic {
      if let firstInteger = Int(first){
          let range: Range<String.Index> = alphabet.range(of: second)!
          let index: Int = alphabet.distance(from: alphabet.startIndex, to: range.lowerBound)
         
        let _: [Int] = Array(firstInteger...9)
          //let myRange: ClosedRange = 0...index
      
        for item in alphabet[0..<index] {
          expando.append(String(item))
          print (item)
        }
       
      }
    }
    
    // W-3 - NOT TESTED
    if first.isAlphabetic && second.isInteger {
      if let secondInteger = Int(second){
          let range: Range<String.Index> = alphabet.range(of: first)!
          let index: Int = alphabet.distance(from: alphabet.startIndex, to: range.upperBound)
         
        let _: [Int] = Array(0...secondInteger)
        //let myRange: ClosedRange = index...25
      
        for item in alphabet[index..<25] {
          expando.append(String(item))
          print (item)
        }
       
      }
    }
    
    // A-G
    if first.isAlphabetic && second.isAlphabetic {
    
      let range: Range<String.Index> = alphabet.range(of: first)!
      let index: Int = alphabet.distance(from: alphabet.startIndex, to: range.lowerBound)
      
      let range2: Range<String.Index> = alphabet.range(of: second)!
      let index2: Int = alphabet.distance(from: alphabet.startIndex, to: range2.upperBound)
      
      //let myRange: ClosedRange = index...index2
     
      for item in alphabet[index..<index2] {
        expando.append(String(item))
      }
      
      // the first character has already been stored
      expando.remove(at: 0)
    }
    //print("\(first):\(second):\(expando)")
      
    return expando
  }
  
} // end class

//extension String {
//    var isInt: Bool {
//        return Int(self) != nil
//    }
//}

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
