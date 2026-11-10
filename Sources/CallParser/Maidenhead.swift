//
//  Maidenhead.swift
//  CallParser
//
//  Converts a Maidenhead grid locator to the coordinates of its centre.
//

import Foundation

enum Maidenhead {

  /// The centre of a 4- or 6-character grid locator (e.g. `CM97` or `CM97ax`).
  /// Longer locators are reduced to their first 6 characters.
  /// - Returns: `nil` if the locator is malformed.
  static func coordinates(for grid: String) -> (latitude: Double, longitude: Double)? {
    let chars = Array(grid.trimmingCharacters(in: .whitespaces).uppercased())
    guard chars.count >= 4 else { return nil }

    // Field: two letters A-R (20° longitude x 10° latitude).
    guard let lonField = letterIndex(chars[0], limit: 18),
          let latField = letterIndex(chars[1], limit: 18),
          // Square: two digits (2° x 1°).
          let lonSquare = chars[2].wholeNumberValue,
          let latSquare = chars[3].wholeNumberValue
    else { return nil }

    var longitude = Double(lonField) * 20 + Double(lonSquare) * 2 - 180
    var latitude = Double(latField) * 10 + Double(latSquare) - 90

    if chars.count >= 6,
       // Subsquare: two letters A-X (5' x 2.5').
       let lonSub = letterIndex(chars[4], limit: 24),
       let latSub = letterIndex(chars[5], limit: 24) {
      longitude += (Double(lonSub) + 0.5) * (2.0 / 24)
      latitude += (Double(latSub) + 0.5) * (1.0 / 24)
    } else {
      // Centre of the square.
      longitude += 1
      latitude += 0.5
    }

    return (latitude: latitude, longitude: longitude)
  }

  /// Zero-based index of an uppercase letter, or `nil` if outside A..<A+limit.
  private static func letterIndex(_ char: Character, limit: Int) -> Int? {
    guard let ascii = char.asciiValue, ascii >= 65 else { return nil }
    let index = Int(ascii) - 65
    return index < limit ? index : nil
  }
}
