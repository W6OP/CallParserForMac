//
//  Extensions.swift
//  CallParser
//
//  Created by Peter Bourget on 8/22/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation

// MARK: - Array Extensions ----------------------------------------------------------------------------

// great but a little slow
extension Array where Element: Equatable {
    func all(where predicate: (Element) -> Bool) -> [Element]  {
        return self.compactMap { predicate($0) ? $0 : nil }
    }
}

// https://stackoverflow.com/questions/25738817/removing-duplicate-elements-from-an-array-in-swift
extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var set = Set<Element>()
        return filter { set.insert($0).inserted }
    }
}

// MARK: - String Protocol Extensions

// also look at https://stackoverflow.com/questions/24092884/get-nth-character-of-a-string-in-swift-programming-language
// https://stackoverflow.com/questions/32305891/index-of-a-substring-in-a-string-with-swift
// https://rbnsn.me/multi-core-array-operations-in-swift
// https://medium.com/better-programming/24-swift-extensions-for-cleaner-code-41e250c9c4c3

/// For string slices
extension StringProtocol where Index == String.Index {
  //let end = mask.endIndex(of: "]")!
  func endIndex<S: StringProtocol>(of string: S, options: String.CompareOptions = []) -> Index? {
    range(of: string, options: options)?.upperBound
  }
}

// MARK: - String Extensions

// https://www.agnosticdev.com/content/how-get-first-or-last-characters-string-swift-4
// Build your own String Extension for grabbing a character at a specific position
// usage if let character = str.character(at: 3)
// nil returned if value to large for string
extension String {
  
  func index(at position: Int, from start: Index? = nil) -> Index? {
    let startingIndex = start ?? startIndex
    return index(startingIndex, offsetBy: position, limitedBy: endIndex)
  }

  func character(at position: Int) -> String? {
    guard position >= 0 && position <= self.count - 1, let indexPosition = index(at: position) else {
      return nil
    }
    return String(self[indexPosition])
  }
  
  // ----------------------
  
      var length: Int {
          return count
      }

      subscript (i: Int) -> String {
          return self[i ..< i + 1]
      }

      func substring(fromIndex: Int) -> String {
          return self[min(fromIndex, length) ..< length]
      }

      func substring(toIndex: Int) -> String {
          return self[0 ..< max(0, toIndex)]
      }

      subscript (r: Range<Int>) -> String {
          let range = Range(uncheckedBounds: (lower: max(0, min(length, r.lowerBound)),
                                              upper: min(length, max(0, r.upperBound))))
          let start = index(startIndex, offsetBy: range.lowerBound)
          let end = index(start, offsetBy: range.upperBound - range.lowerBound)
          return String(self[start ..< end])
      }
  
  // in some cases these may be preferable to those above
  // allows to use simple Ints for subscripting strings
  
//  subscript (i: Int) -> Character {
//      return self[index(startIndex, offsetBy: i)]
//  }
//
//  subscript (bounds: CountableRange<Int>) -> Substring {
//      let start = index(startIndex, offsetBy: bounds.lowerBound)
//      let end = index(startIndex, offsetBy: bounds.upperBound)
//      if end < start { return "" }
//      return self[start..<end]
//  }
//
//  subscript (bounds: CountableClosedRange<Int>) -> Substring {
//      let start = index(startIndex, offsetBy: bounds.lowerBound)
//      let end = index(startIndex, offsetBy: bounds.upperBound)
//      if end < start { return "" }
//      return self[start...end]
//  }
//
//  subscript (bounds: CountablePartialRangeFrom<Int>) -> Substring {
//      let start = index(startIndex, offsetBy: bounds.lowerBound)
//      let end = index(endIndex, offsetBy: -1)
//      if end < start { return "" }
//      return self[start...end]
//  }
//
//  subscript (bounds: PartialRangeThrough<Int>) -> Substring {
//      let end = index(startIndex, offsetBy: bounds.upperBound)
//      if end < startIndex { return "" }
//      return self[startIndex...end]
//  }
//
//  subscript (bounds: PartialRangeUpTo<Int>) -> Substring {
//      let end = index(startIndex, offsetBy: bounds.upperBound)
//      if end < startIndex { return "" }
//      return self[startIndex..<end]
//  }
 // ------------------------------------------------------------------
  
  /// trim string - remove spaces and other similar symbols (for example, new lines and tabs)
  var trimmed: String {
      self.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  
  mutating func trim() {
      self = self.trimmed
  }
  // ------------------------------------------------------------------
  // get date from string
  func toDate(format: String) -> Date? {
      let df = DateFormatter()
      df.dateFormat = format
      return df.date(from: self)
  }
  // ------------------------------------------------------------------
  
  // test if a character is an int
  var isInteger: Bool {
    return Int(self) != nil
  }
  
  var isNumeric: Bool {
    guard self.count > 0 else { return false }
    let nums: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    return Set(self).isSubset(of: nums)
  }
  
  var containsOnlyDigits: Bool {
      let notDigits = NSCharacterSet.decimalDigits.inverted
      return rangeOfCharacter(from: notDigits, options: String.CompareOptions.literal, range: nil) == nil
  }
  
  var isAlphabetic: Bool {
    guard self.count > 0 else { return false }
    let alphas: Set<Character> = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]
    return Set(self).isSubset(of: alphas)
  }
  
  func isAlphanumeric() -> Bool {
    return self.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil && self != ""
  }
  
//  var isAlphanumeric: Bool {
//      !isEmpty && range(of: "[^a-zA-Z0-9]", options: .regularExpression) == nil
//  }
  
  // ------------------------------------------------------------------
  // here to end
  // https://stackoverflow.com/questions/29971505/filter-non-digits-from-string
  var onlyDigits: String { return onlyCharacters(charSets: [.decimalDigits]) }
  var onlyLetters: String { return onlyCharacters(charSets: [.letters]) }

  private func filterCharacters(unicodeScalarsFilter closure: (UnicodeScalar) -> Bool) -> String {
    return String(String.UnicodeScalarView(unicodeScalars.filter { closure($0) }))
  }

  private func filterCharacters(definedIn charSets: [CharacterSet], unicodeScalarsFilter: (CharacterSet, UnicodeScalar) -> Bool) -> String {
    if charSets.isEmpty { return self }
    let charSet = charSets.reduce(CharacterSet()) { return $0.union($1) }
    return filterCharacters { unicodeScalarsFilter(charSet, $0) }
  }

  func removeCharacters(charSets: [CharacterSet]) -> String { return filterCharacters(definedIn: charSets) { !$0.contains($1) } }
  func removeCharacters(charSet: CharacterSet) -> String { return removeCharacters(charSets: [charSet]) }

  func onlyCharacters(charSets: [CharacterSet]) -> String { return filterCharacters(definedIn: charSets) { $0.contains($1) } }
  func onlyCharacters(charSet: CharacterSet) -> String { return onlyCharacters(charSets: [charSet]) }

  //extension String { // count instances of a character
  // https://stackoverflow.com/questions/31746223/number-of-occurrences-of-substring-in-string-in-swift
  // stringToFind must be at least 1 character.
  // usage "aaaa".countInstances(of: "aa")
      func countInstances(of stringToFind: String) -> Int {
          assert(!stringToFind.isEmpty)
          var count = 0
          var searchRange: Range<String.Index>?
          while let foundRange = range(of: stringToFind, options: [], range: searchRange) {
              count += 1
              searchRange = Range(uncheckedBounds: (lower: foundRange.upperBound, upper: endIndex))
          }
          return count
      }
  //}

}

// MARK: - Extension Collection ----------------------------------------------------------------------------

// if the digit is the next in value 5,6 = true
extension Int {
  func isSuccessor(first: Int, second: Int) -> Bool {
    if second - first == 1 {
      return true
    }
    return false
  }
  
  func toDouble() -> Double {
      Double(self)
  }
  
  func toString() -> String {
      "\(self)"
  }
}

extension Double {
    func toInt() -> Int {
        Int(self)
    }
  
  func toString() -> String {
      String(format: "%.02f", self)
  }
}

// get string from date
extension Date {
    func toString(format: String) -> String {
        let df = DateFormatter()
        df.dateFormat = format
        return df.string(from: self)
    }
}

//  allows to get the app version from Info.plist
// let appVersion = Bundle.mainAppVersion
extension Bundle {
    var appVersion: String? {
        self.infoDictionary?["CFBundleShortVersionString"] as? String
    }
    
    static var mainAppVersion: String? {
        Bundle.main.appVersion
    }
}
