//
//  CallStructure.swift
//  CallParser
//
//  Created by Peter Bourget on 6/13/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation

/// Structure describing the type of call sign we are processing.
public struct CallStructure {

  private let singleCharacterPrefixes: [String] = ["F", "G", "M", "I", "R", "W" ]

  public var pattern = ""
  public var prefix: String!
  public var baseCall: String!
  public var fullCall: String
  var suffix1: String!
  private var suffix2: String!

  private var callSignFlags = [CallSignFlags]()
  public var callStructureType = CallStructureType.invalid
  private var portablePrefixShapePatterns: Set<String>!

  // added for use with CallBack
  public var spotId = 0
  public var sequence = 0

  /// Constructor
  /// - Parameters:
  ///   - callSign: call sign to process
  ///   - portablePrefixShapePatterns: set of valid portable prefix shape
  ///     patterns (e.g. `"@@/"`, `"@@#/"`). Used to gate whether a 2-or-more-
  ///     character alpha/digit sequence should be treated as a known portable.
  public init(callSign: String, portablePrefixShapePatterns: Set<String>) {
    self.portablePrefixShapePatterns = portablePrefixShapePatterns

    fullCall = callSign
    splitCallSign(callSign: callSign)
  }

  /// Split the call sign into individual components.
  /// - Parameter callSign: call sign to split.
  mutating func splitCallSign(callSign: String) {

    if callSign.components(separatedBy: "/").count > 3 {
      return
    }

    let components = callSign.components(separatedBy: "/")

    // components.forEach { // slower
    for item in components {
      guard getComponentType(callSign: item) != StringTypes.invalid else {
        return
      }
    }

    analyzeComponents(components: components)
  }

  /// Determine the CallStructureType for this CallStructure.
  /// - Parameter components: individual components of a call sign.
  mutating func analyzeComponents(components: [String]) {

    switch components.count {
    case 0:
      return
    case 1:
      if verifyIfCallSign(component: components[0]) == ComponentType.callSign {
        baseCall = components[0]
        callStructureType = CallStructureType.call
      } else {
        callStructureType = CallStructureType.invalid
      }
    case 2:
      processComponents(firstComponent: components[0], secondComponent: components[1])
    case 3:
      processComponents(firstComponent: components[0], secondComponent: components[1], thirdComponent: components[2])
    default:
      return
    }
  }

  /// Just a quick test for grossly invalid call signs.
  /// - Parameter callSign: call sign
  /// - Returns: valid or invalid StringType
  func getComponentType(callSign: String) -> StringTypes {

    // THIS NEEDS CHECKING
    switch false {
    case String(callSign.trimmingCharacters(in: .whitespaces)).isEmpty:
      return StringTypes.valid
    case String(callSign.trimmingCharacters(in: .punctuationCharacters)).isEmpty:
      return StringTypes.valid
    case String(callSign.trimmingCharacters(in: .illegalCharacters)).isEmpty:
      return StringTypes.valid
    default:
      return StringTypes.invalid
    }
  }

  /// Set the flags associated with this call sign
  /// - Parameters:
  ///   - firstComponent: first component of the call sign.
  ///   - secondComponent: second component of the call sign.
  mutating func setCallSignFlags(firstComponent: String, secondComponent: String) {

    switch firstComponent {
    case "R":
      callSignFlags.append(CallSignFlags.beacon)

    case "B":
      callSignFlags.append(CallSignFlags.beacon)

    case "P":
      if secondComponent == "QRP" {
        callSignFlags.append(CallSignFlags.qrp)
      }
      callSignFlags.append(CallSignFlags.portable)

    case "QRP":
      if secondComponent == "P" {
        callSignFlags.append(CallSignFlags.portable)
      }
      callSignFlags.append(CallSignFlags.qrp)

    case "M":
      callSignFlags.append(CallSignFlags.portable)

    case "MM":
      callSignFlags.append(CallSignFlags.maritime)

    default:
      callSignFlags.append(CallSignFlags.portable)
    }
  }

  // The classification cases are clearest kept together.
  // swiftlint:disable cyclomatic_complexity
  /**
   one of "@","@@","#@","#@@" followed by 1-4 digits followed by 1-6 letters
   ValidPrefixes = ':@:@@:@@#:@@#@:@#:@#@:@##:#@:#@@:#@#:#@@#:';
   ValidStructures = ':C:C#:C#M:C#T:CM:CM#:CMM:CMP:CMT:CP:CPM:CT:PC:PCM:PCT:';
   */

  /// Determine the ComponentType for the input string.
  /// - Parameters:
  ///   - candidate: call sign component to be analyzed.
  ///   - position: component position.
  /// - Returns: ComponentType of the input.
  mutating func getComponentType(candidate: String, position: Int) -> ComponentType {

    let validPrefixes = ["@", "@@", "@@#", "@@#@", "@#", "@#@", "@##", "#@", "#@@", "#@#", "#@@#"]
    let validPrefixOrCall = ["@@#@", "@#@"]
    var componentType = ComponentType.unknown

    pattern = buildPattern(candidate: candidate)

    switch true {

    case pattern.isEmpty:
      return ComponentType.unknown

    case position == 1 && candidate == "MM":
      return ComponentType.prefix

    case position == 1 && candidate.count == 1:
      return verifyIfPrefix(candidate: candidate, position: position)

    case isSuffix(candidate: candidate):
      return ComponentType.portable

    case candidate.count == 1:
      if candidate.isInteger {
        return ComponentType.numeric
      } else {
        return ComponentType.text
      }

    case candidate.isAlphabetic:
      if candidate.count > 2 {
        return ComponentType.text
      }
      if verifyIfPrefix(candidate: candidate, position: position) == ComponentType.prefix {
        return ComponentType.prefix
      }
      return ComponentType.text

      // this first case is somewhat redundant
    case validPrefixOrCall.contains(pattern):
      if verifyIfPrefix(candidate: candidate, position: position) != ComponentType.prefix {
        return ComponentType.callSign
      } else {
        if verifyIfCallSign(component: candidate) == ComponentType.callSign {
          componentType = ComponentType.unknown
        } else {
          componentType = ComponentType.prefix
        }
      }
      return componentType

    case validPrefixes.contains(pattern) &&
      verifyIfPrefix(candidate: candidate, position: position) == ComponentType.prefix:
      return ComponentType.prefix

    case verifyIfCallSign(component: candidate) == ComponentType.callSign:
      return ComponentType.callSign

    default:
      if candidate.isAlphabetic {
        return ComponentType.text
      }
    }

    return ComponentType.unknown
  }
  // swiftlint:enable cyclomatic_complexity

  /**
   one of "@","@@","#@","#@@" followed by 1-4 digits followed by 1-6 letters
   create pattern from call and see if it matches valid patterns
   */

  /// Determine if this matches the pattern for a valid call sign.
  /// - Parameter component: the call sign component to be verified.
  /// - Returns: a valid or invalid ComponentType.
  func verifyIfCallSign(component: String) -> ComponentType {

    var characters = component.makeIterator()
    guard let firstCharacter = characters.next(), let secondCharacter = characters.next() else {
      return .invalid
    }
    let first = String(firstCharacter)
    let second = String(secondCharacter)
    var candidate = component

    switch true {
    case first.isAlphabetic && second.isAlphabetic: // "@@"
      candidate.removeFirst(2)
    case first.isAlphabetic: // "@"
      candidate.removeFirst()
    case first.isInteger && second.isAlphabetic: // "#@"
      candidate.removeFirst(2)
    default:
      break
    }

    var digits = 0

    while candidate.containsNumbers() {
      if let firstCharacter = candidate.first, String(firstCharacter).isInteger {
        digits += 1
      }
      candidate.remove(at: candidate.startIndex)
      if candidate.count == 0 {
        return ComponentType.invalid
      }
    }

    if digits > 0 && digits <= 4 && candidate.count <= 6 &&
      candidate.rangeOfCharacter(from: CharacterSet.alphanumerics) != nil {
      return ComponentType.callSign // needs checking
    }

    return ComponentType.invalid
  }

  /// Test if a candidate is truly a prefix.
  /// - Parameters:
  ///   - candidate: string to be evaluated.
  ///   - position: indicates if this is the first or second component
  /// - Returns: the ComponentType of the input string.
  mutating func verifyIfPrefix(candidate: String, position: Int) -> ComponentType {

    let validPrefixes = ["@", "@@", "@@#", "@@#@", "@#", "@#@", "@##", "#@", "#@@", "#@#", "#@@#"]

    if candidate.count == 1 {
      switch position {
      case 1:
        if singleCharacterPrefixes.contains(candidate) {
          return ComponentType.prefix
        } else {
          return ComponentType.text
        }
      default:
        return ComponentType.text
      }
    }

    if validPrefixes.contains(pattern) {
      if portablePrefixShapePatterns.contains(pattern + "/") {
        return ComponentType.prefix
      }
    }

    return ComponentType.text
  }

  /*
   Build the pattern from the mask
   KG4@@.
   [AKNW]H7K[./]
   AX9[ABD-KOPQS-VYZ][.ABD-KOPQS-VYZ] @@#@. and @@#@@.
   The [.A-KOPQS-VYZ] mask for the second letter of the suffix means that the call should either
   end there (no second letter) or be one of the listed letters.
   */

  // Consider joined(separator:) to reduce intermediate string allocations.

  /// Build the pattern of meta characters that represents the input.
  /// - Parameter candidate: call sign or prefix.
  /// - Returns: meta character pattern.
  func buildPattern(candidate: String) -> String {
    var pattern = ""

    // with 1371294 iterations this is 10 seconds faster
    // for item in candidate {
    candidate.forEach {
      if $0.isNumber {
        pattern += "#"
      } else if $0.isLetter {
        pattern += "@"
      } else {
        pattern += String($0)
      }
    }
    return pattern
  }

  /// Determine if a string is a valid suffix.
  /// - Parameter candidate: string to be evaluated.
  /// - Returns: bool
  func isSuffix(candidate: String) -> Bool {
    let validSuffixes = ["A", "B", "M", "P", "MM", "AM", "QRP", "QRPP", "LH", "LGT", "ANT", "WAP", "AAW", "FJL"]

    if validSuffixes.contains(candidate) {
      return true
    }

    return false
  }

  /// Should this string be considered as text.
  /// - Parameter candidate: string to be evaluated.
  /// - Returns: bool
  func iSText(candidate: String) -> Bool {

    // /1J
    if candidate.count == 2 {
      return true
    }

    // /JOHN
    if candidate.isAlphabetic {
      return true
    }

    // /599
    if candidate.isNumeric {
      return true
    }

    if candidate.isAlphanumeric() {
      return false
    }

    return false
  }

} // end class
