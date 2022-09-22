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
  public var fullCall: String!
  private var suffix1: String!
  private var suffix2: String!
  
  private var callSignFlags = [CallSignFlags]()
  public var callStructureType = CallStructureType.invalid
  private var portablePrefixes: [String: [PrefixData]]!

  // added for use with CallBack
  public var spotId = 0
  public var sequence = 0

  /// Constructor
  /// - Parameters:
  ///   - callSign: call sign to process
  ///   - portablePrefixes: array of portablePrefixes
  public init(callSign: String, portablePrefixes: [String: [PrefixData]]) {
    self.portablePrefixes = portablePrefixes
    
    fullCall = callSign
    splitCallSign(callSign: callSign);
  }
  

  /// Split the call sign into individual components.
  /// - Parameter callSign: call sign to split.
  mutating func splitCallSign(callSign: String) {
    
    if callSign.components(separatedBy:"/").count > 3 {
      return
    }
    
    let components = callSign.components(separatedBy:"/")

    //components.forEach { // slower
    for item in components {
      guard getComponentType(callSign: item) != StringTypes.invalid else {
        return
      }
    }
    
    analyzeComponents(components: components);
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
      }
      else {
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

  /// Determine the type of this CallStructure from the call sign components.
  /// - Parameters:
  ///   - firstComponent: first component of the call sign.
  ///   - secondComponent: second component of the call sign.
  mutating func processComponents(firstComponent: String, secondComponent: String) {

    var componentTypes =
    (firstComponentType: getComponentType(candidate: firstComponent, position: 1),
     secondComponentType: getComponentType(candidate: secondComponent, position: 2))
    
    if componentTypes.firstComponentType == ComponentType.unknown ||
        componentTypes.secondComponentType == ComponentType.unknown {

      componentTypes = resolveAmbiguities(firstComponentType: componentTypes.firstComponentType, secondComponentType: componentTypes.secondComponentType)
    }

    baseCall = firstComponent
    prefix = secondComponent
    
    // ValidStructures = 'C#:CM:CP:CT:PC:'
    switch true {
      // if either invalid short circuit all the checks and exit immediately
    case componentTypes.firstComponentType == ComponentType.invalid ||
      componentTypes.secondComponentType == ComponentType.invalid:
      return
      
      // CP
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.prefix:
      callStructureType = CallStructureType.callPrefix
      
      // PC
    case componentTypes.firstComponentType == ComponentType.prefix &&
      componentTypes.secondComponentType == ComponentType.callSign:
      callStructureType = CallStructureType.prefixCall
      setCallSignFlags(firstComponent: firstComponent, secondComponent: "")
      baseCall = secondComponent;
      prefix = firstComponent;
      
      // PP
    case componentTypes.firstComponentType == ComponentType.prefix &&
      componentTypes.secondComponentType == ComponentType.portable:
      callStructureType = CallStructureType.invalid
      
      // CC  ==> CP - check BU - BY - VU4 - VU7
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.callSign:
      if (secondComponent.prefix(1) == "B") {
        callStructureType = CallStructureType.callPrefix;
        setCallSignFlags(firstComponent: firstComponent, secondComponent: "");
      } else if firstComponent.prefix(3) == "VU4" ||
                firstComponent.prefix(3) == "VU7" {
        callStructureType = CallStructureType.callPrefix;
        setCallSignFlags(firstComponent: secondComponent, secondComponent: "");
      }
      
      // CT
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.text:
      callStructureType = CallStructureType.callText
      setCallSignFlags(firstComponent: secondComponent, secondComponent: "")
      
      // TC
    case componentTypes.firstComponentType == ComponentType.text &&
      componentTypes.secondComponentType == ComponentType.callSign:
      callStructureType = CallStructureType.callText
      baseCall = secondComponent;
      prefix = firstComponent;
      setCallSignFlags(firstComponent: secondComponent, secondComponent: "")
      
      // C#
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.numeric:
      callStructureType = CallStructureType.callDigit
      setCallSignFlags(firstComponent: secondComponent, secondComponent: "")
      
      // CM
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.portable:
      callStructureType = CallStructureType.callPortable
      setCallSignFlags(firstComponent: secondComponent, secondComponent: "")
      
      // PU
    case componentTypes.firstComponentType == ComponentType.prefix &&
      componentTypes.secondComponentType == ComponentType.unknown:
      callStructureType = CallStructureType.prefixCall
      baseCall = secondComponent;
      prefix = firstComponent;
      
    default:
      return
    }
  }

  /// Determine the type of CallStructure from the call sign components.
  /// - Parameters:
  ///   - firstComponent: first component of the call sign.
  ///   - secondComponent: second component of the call sign.
  ///   - thirdComponent: third component of the call sign.
  mutating func processComponents(firstComponent: String, secondComponent: String, thirdComponent: String) {

    var componentTypes =
    (firstComponentType: getComponentType(candidate: firstComponent, position: 1),
     secondComponentType: getComponentType(candidate: secondComponent, position: 2))

    let thirdComponentType = getComponentType(candidate: thirdComponent, position: 3)

    if componentTypes.firstComponentType == ComponentType.unknown ||
        componentTypes.secondComponentType == ComponentType.unknown {

      componentTypes = resolveAmbiguities(firstComponentType: componentTypes.firstComponentType, secondComponentType: componentTypes.secondComponentType)
    }
    
    baseCall = firstComponent
    prefix = secondComponent
    suffix1 = thirdComponent;
    
    // ValidStructures = 'C#M:C#T:CM#:CMM:CMP:CMT:CPM:PCM:PCT:'

    switch true {
      // if all are invalid short circuit all the checks and exit immediately
    case componentTypes.firstComponentType == ComponentType.invalid &&
      componentTypes.secondComponentType == ComponentType.invalid &&
      thirdComponentType == ComponentType.invalid:
      return
      
      // C#M
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.numeric &&
      thirdComponentType == ComponentType.portable:

      callStructureType = CallStructureType.callDigitPortable
      setCallSignFlags(firstComponent: thirdComponent, secondComponent: "")

      // C#T
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.numeric &&
      thirdComponentType == ComponentType.text:

      callStructureType = CallStructureType.callDigitText
      setCallSignFlags(firstComponent: thirdComponent, secondComponent: "")
      
      // CMM
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.portable &&
      thirdComponentType == ComponentType.portable:

      callStructureType = CallStructureType.callPortablePortable
      setCallSignFlags(firstComponent: secondComponent, secondComponent: "")

      // CMP
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.portable &&
      thirdComponentType == ComponentType.prefix:

      baseCall = firstComponent
      prefix = thirdComponent
      suffix1 = secondComponent
      callStructureType = CallStructureType.callPortablePrefix
      setCallSignFlags(firstComponent: secondComponent, secondComponent: "")
      
      
      // CMT
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.portable &&
      thirdComponentType == ComponentType.text:

      callStructureType = CallStructureType.callPortableText
      setCallSignFlags(firstComponent: secondComponent, secondComponent: "")
      return;
      
      // CPM
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.prefix &&
      thirdComponentType == ComponentType.portable:

      callStructureType = CallStructureType.callPrefixPortable
      setCallSignFlags(firstComponent: thirdComponent, secondComponent: "")

      // PCM
    case componentTypes.firstComponentType == ComponentType.prefix &&
      componentTypes.secondComponentType == ComponentType.callSign &&
      thirdComponentType == ComponentType.portable:

      baseCall = secondComponent
      prefix = firstComponent
      suffix1 = thirdComponent
      callStructureType = CallStructureType.prefixCallPortable
      
      // PCT
    case componentTypes.firstComponentType == ComponentType.prefix &&
      componentTypes.secondComponentType == ComponentType.callSign &&
      thirdComponentType == ComponentType.text:

      baseCall = secondComponent
      prefix = firstComponent
      suffix1 = thirdComponent
      callStructureType = CallStructureType.prefixCallText
      
      // CM#
    case componentTypes.firstComponentType == ComponentType.callSign &&
      componentTypes.secondComponentType == ComponentType.portable &&
      thirdComponentType == ComponentType.numeric:

      baseCall = firstComponent
      prefix = thirdComponent
      suffix1 = secondComponent
      setCallSignFlags(firstComponent: thirdComponent, secondComponent: "")
      callStructureType = CallStructureType.callDigitPortable
      
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
    case callSign.trimmingCharacters(in: .whitespaces).isEmpty:
      return StringTypes.valid
    case callSign.trimmingCharacters(in: .punctuationCharacters).isEmpty:
      return StringTypes.valid
    case callSign.trimmingCharacters(in: .illegalCharacters).isEmpty:
      return StringTypes.valid
    default:
      return StringTypes.invalid
    }
  }

  /// Set the flags associated with this call sign
  /// - Parameters:
  ///   - firstComponent: first component of the call sign.
  ///   - secondComponent: second component of the call sign.
  mutating func setCallSignFlags(firstComponent: String, secondComponent: String){
    
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

  /// Resolve the component types when one component is unknown.
  /// - Parameters:
  ///   - firstComponentType: firstComponentType description
  ///   - secondComponentType: secondComponentType description
  /// - Returns: ComponentType for each component
  func resolveAmbiguities(firstComponentType: ComponentType, secondComponentType: ComponentType) -> (ComponentType, ComponentType) {

    var componentTypes = (componentType1: ComponentType.unknown, componentType2: ComponentType.unknown)

    switch true {
      // UU --> PC
    case firstComponentType == ComponentType.unknown && secondComponentType == ComponentType.unknown:
      componentTypes.componentType1 = ComponentType.prefix
      componentTypes.componentType2 = ComponentType.callSign

      // CU --> CP - I don't agree with this --> CT
    case firstComponentType == ComponentType.callSign && secondComponentType ==    ComponentType.unknown:
      componentTypes.componentType1 = ComponentType.callSign
      componentTypes.componentType2 = ComponentType.text

      // UC --> PC - I don't agree with this --> TC
    case firstComponentType == ComponentType.unknown && secondComponentType == ComponentType.callSign:
      componentTypes.componentType1 = ComponentType.prefix
      componentTypes.componentType2 = ComponentType.callSign

      // UP --> CP
    case firstComponentType == ComponentType.unknown && secondComponentType == ComponentType.prefix:
      componentTypes.componentType1 = ComponentType.callSign
      componentTypes.componentType2 = ComponentType.prefix

      // PU --> PC
    case firstComponentType == ComponentType.prefix && secondComponentType == ComponentType.unknown:
      componentTypes.componentType1 = ComponentType.prefix
      componentTypes.componentType2 = ComponentType.callSign

      // U --> C
    case firstComponentType == ComponentType.unknown:
      componentTypes.componentType1 = ComponentType.callSign
      componentTypes.componentType2 = secondComponentType

      // U --> C
    case secondComponentType == ComponentType.unknown:
      componentTypes.componentType1 = firstComponentType
      componentTypes.componentType2 = ComponentType.callSign

    default:
      componentTypes.componentType1 = ComponentType.unknown
      componentTypes.componentType2 = ComponentType.unknown
    }

    return componentTypes
  }
  
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
      if verifyIfPrefix(candidate: candidate, position: position) == ComponentType.prefix
      {
        return ComponentType.prefix;
      }
      return ComponentType.text;
      
      // this first case is somewhat redundant
    case validPrefixOrCall.contains(pattern):
      if verifyIfPrefix(candidate: candidate, position: position) != ComponentType.prefix
      {
        return ComponentType.callSign;
      } else {
        if verifyIfCallSign(component: candidate) == ComponentType.callSign {
          componentType = ComponentType.unknown
        } else {
          componentType = ComponentType.prefix
        }
      }
      return componentType
      
    case validPrefixes.contains(pattern) && verifyIfPrefix(candidate: candidate, position: position) == ComponentType.prefix:
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
  
  /**
   one of "@","@@","#@","#@@" followed by 1-4 digits followed by 1-6 letters
   create pattern from call and see if it matches valid patterns
   */

  /// Determine if this matches the pattern for a valid call sign.
  /// - Parameter component: the call sign component to be verified.
  /// - Returns: a valid or invalid ComponentType.
  func verifyIfCallSign(component: String) -> ComponentType {
    
    let first = component[0]
    let second = component[1]
    var range = component.startIndex...component.index(component.startIndex, offsetBy: 1)
    
    var candidate = component
    
    switch true {
    case first.isAlphabetic && second.isAlphabetic: // "@@"
      candidate.removeSubrange(range)
    case first.isAlphabetic: // "@"
      candidate.remove(at: candidate.startIndex)
    case String(first).isInteger && second.isAlphabetic: // "#@"
      range = candidate.startIndex...candidate.index(candidate.startIndex, offsetBy: 1)
      candidate.removeSubrange(range)
    case String(first).isInteger && second.isAlphabetic && candidate[2].isAlphabetic: //"#@@"
      range = candidate.startIndex...candidate.index(candidate.startIndex, offsetBy: 2)
      candidate.removeSubrange(range)

    default:
      break
    }
    
    var digits = 0

    while candidate.containsNumbers() {
      if String(candidate[0]).isInteger {
        digits += 1
      }
      candidate.remove(at: candidate.startIndex)
      if candidate.count == 0 {
        return ComponentType.invalid
      }
    }
    
    if digits > 0 && digits <= 4 {
      if candidate.count <= 6 {
        if candidate.rangeOfCharacter(from: CharacterSet.alphanumerics) != nil {
          return ComponentType.callSign // needs checking
        }
      }
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
        if singleCharacterPrefixes.contains(candidate){
          return ComponentType.prefix;
        }
        else {
          return ComponentType.text
        }
      default:
        return ComponentType.text
      }
    }
    
    if validPrefixes.contains(pattern){
      if portablePrefixes[pattern + "/"] != nil {
        return ComponentType.prefix
      }
    }
    
    return ComponentType.text;
  }
  
  /**
   Build the pattern from the mask
   KG4@@.
   [AKNW]H7K[./]
   AX9[ABD-KOPQS-VYZ][.ABD-KOPQS-VYZ] @@#@. and @@#@@.
   The [.A-KOPQS-VYZ] mask for the second letter of the suffix means that the call should either end there (no second letter) or be one of the listed letters.
   */

  /// Build the pattern of meta characters that represents the input.
  /// - Parameter candidate: call sign or prefix.
  /// - Returns: meta character pattern.
  func buildPattern(candidate: String)-> String {
    var pattern = ""
    
    // with 1371294 iterations this is 10 seconds faster
    // for item in candidate {
    candidate.forEach {
      if ($0.isNumber) {
        pattern += "#"
      }
      else if ($0.isLetter)  {
        pattern += "@"
      }
      else {
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
    
    if validSuffixes.contains(candidate){
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
