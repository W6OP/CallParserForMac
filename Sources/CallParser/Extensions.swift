//
//  Extensions.swift
//  CallParser
//
//  Created by Peter Bourget on 8/22/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation

// MARK: - String Extensions

extension String {

  /// trim string - remove spaces and other similar symbols (for example, new lines and tabs)
  var trimmed: String {
      self.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // test if a character is an int
  var isInteger: Bool {
    return Int(self) != nil
  }

  var isNumeric: Bool {
    guard self.count > 0 else { return false }
    let nums: Set<Character> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    return Set(self).isSubset(of: nums)
  }

  var isAlphabetic: Bool {
    guard self.count > 0 else { return false }
    let alphas: Set<Character> = [
      "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
      "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"
    ]
    return Set(self).isSubset(of: alphas)
  }

  func isAlphanumeric() -> Bool {
    return self.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil && self != ""
  }

  func containsNumbers() -> Bool {
    rangeOfCharacter(from: .decimalDigits) != nil
  }

//  var isAlphanumeric: Bool {
//      !isEmpty && range(of: "[^a-zA-Z0-9]", options: .regularExpression) == nil
//  }

  // ------------------------------------------------------------------
  // here to end
  // https://stackoverflow.com/questions/29971505/filter-non-digits-from-string
  var onlyDigits: String { return onlyCharacters(charSets: [.decimalDigits]) }

  private func filterCharacters(unicodeScalarsFilter closure: (UnicodeScalar) -> Bool) -> String {
    return String(String.UnicodeScalarView(unicodeScalars.filter { closure($0) }))
  }

  private func filterCharacters(
    definedIn charSets: [CharacterSet],
    unicodeScalarsFilter: (CharacterSet, UnicodeScalar) -> Bool
  ) -> String {
    if charSets.isEmpty { return self }
    let charSet = charSets.reduce(CharacterSet()) { return $0.union($1) }
    return filterCharacters { unicodeScalarsFilter(charSet, $0) }
  }

  func onlyCharacters(charSets: [CharacterSet]) -> String {
    filterCharacters(definedIn: charSets) { $0.contains($1) }
  }

}
