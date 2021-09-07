//
//  CallStructure.swift
//  CallParser
//
//  Created by Peter Bourget on 6/13/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation

public struct CallStructure {
  
  private var singleCharacterPrefixes: [String] = ["F", "G", "M", "I", "R", "W" ]
  
  public var pattern = ""
  public var prefix: String!
  public var baseCall: String!
  public var fullCall: String!
  private var suffix1: String!
  private var suffix2: String!
  
  private var callSignFlags = [CallSignFlags]()
  public var callStructureType = CallStructureType.invalid
  private var portablePrefixes: [String: [PrefixData]]!
  
  /**
   Constructor
   */
  public init(callSign: String, portablePrefixes: [String: [PrefixData]]) {
    self.portablePrefixes = portablePrefixes
    
    fullCall = callSign
    splitCallSign(callSign: callSign);
  }
  
  /**
   Split the call sign into individual components
   */
  mutating func splitCallSign(callSign: String) {
    
    if callSign.components(separatedBy:"/").count > 3 {
      return
    }
    
    let components = callSign.components(separatedBy:"/")
    
    if components.contains("") {
      _=1
    }
    
    //components.forEach { // slower
    for item in components {
      if getComponentType(callSign: item) == StringTypes.invalid {
        return
      }
    }
    
    analyzeComponents(components: components);
  }

  /**
   
   */
  mutating func analyzeComponents(components: [String]) {
    
    switch components.count {
    case 0:
      return
    case 1:
      if verifyIfCallSign(component: components[0]) == ComponentType.callSign
      {
        baseCall = components[0];
        callStructureType = CallStructureType.call;
      }
      else
      {
        callStructureType = CallStructureType.invalid;
      }
    case 2:
      processComponents(component0: components[0], component1: components[1]);
    case 3:
      processComponents(component0: components[0], component1: components[1], component2: components[2]);
    default:
      return
    }
  }
  
  /**
   
   */
  mutating func processComponents(component0: String, component1: String) {
    
    //var componentType = ComponentType.Invalid
    var component0Type: ComponentType
    var component1Type: ComponentType
    
    component0Type = getComponentType(candidate: component0, position: 1)
    component1Type = getComponentType(candidate: component1, position: 2)
    
    if component0Type == ComponentType.unknown || component1Type == ComponentType.unknown {
      resolveAmbiguities(componentType0: component0Type, componentType1: component1Type, component0Type: &component0Type, component1Type: &component1Type);
    }
    
    baseCall = component0
    prefix = component1
    
    // ValidStructures = 'C#:CM:CP:CT:PC:'
    
    switch true {
    // if either invalid short circuit all the checks and exit immediately
    case component0Type == ComponentType.invalid || component1Type == ComponentType.invalid:
      return
      
    // CP
    case component0Type == ComponentType.callSign && component1Type == ComponentType.prefix:
      callStructureType = CallStructureType.callPrefix
      
    // PC
    case component0Type == ComponentType.prefix && component1Type == ComponentType.callSign:
      callStructureType = CallStructureType.prefixCall
      setCallSignFlags(component1: component0, component2: "")
      baseCall = component1;
      prefix = component0;
      
    // PP
    case component0Type == ComponentType.prefix && component1Type == ComponentType.portable:
      callStructureType = CallStructureType.invalid
      
    // CC  ==> CP - check BU - BY - VU4 - VU7
    case component0Type == ComponentType.callSign && component1Type == ComponentType.callSign:
      if (component1.prefix(1) == "B") {
        callStructureType = CallStructureType.callPrefix;
        setCallSignFlags(component1: component0, component2: "");
      } else if component0.prefix(3) == "VU4" || component0.prefix(3) == "VU7" {
        callStructureType = CallStructureType.callPrefix;
        setCallSignFlags(component1: component1, component2: "");
      }
      
    // CT
    case component0Type == ComponentType.callSign && component1Type == ComponentType.text:
      callStructureType = CallStructureType.callText
      setCallSignFlags(component1: component1, component2: "")
      
      // TC
      case component0Type == ComponentType.text && component1Type == ComponentType.callSign:
        callStructureType = CallStructureType.callText
        baseCall = component1;
        prefix = component0;
        setCallSignFlags(component1: component1, component2: "")
      
    // C#
    case component0Type == ComponentType.callSign && component1Type == ComponentType.numeric:
      callStructureType = CallStructureType.callDigit
      setCallSignFlags(component1: component1, component2: "")
      
    // CM
    case component0Type == ComponentType.callSign && component1Type == ComponentType.portable:
      callStructureType = CallStructureType.callPortable
      setCallSignFlags(component1: component1, component2: "")
      
    // PU
    case component0Type == ComponentType.prefix && component1Type == ComponentType.unknown:
      callStructureType = CallStructureType.prefixCall
      baseCall = component1;
      prefix = component0;
      
    default:
      return
    }
  }
  
  /**
   
   */
  mutating func processComponents(component0: String, component1: String, component2: String) {
    
    var component0Type: ComponentType
    var component1Type: ComponentType
    var component2Type: ComponentType
    
    component0Type = getComponentType(candidate: component0, position: 1)
    component1Type = getComponentType(candidate: component1, position: 2)
    component2Type = getComponentType(candidate: component2, position: 3)
    
    if component0Type == ComponentType.unknown || component1Type == ComponentType.unknown {
      // this should probably be expanded
      resolveAmbiguities(componentType0: component0Type, componentType1: component1Type, component0Type: &component0Type, component1Type: &component1Type)
    }
    
    baseCall = component0
    prefix = component1
    suffix1 = component2;
    
    // ValidStructures = 'C#M:C#T:CM#:CMM:CMP:CMT:CPM:PCM:PCT:'

    switch true {
    // if all are invalid short cicuit all the checks and exit immediately
    case component0Type == ComponentType.invalid && component1Type == ComponentType.invalid && component2Type == ComponentType.invalid:
      return
      
    // C#M
    case component0Type == ComponentType.callSign && component1Type == ComponentType.numeric && component2Type == ComponentType.portable:
      callStructureType = CallStructureType.callDigitPortable
      setCallSignFlags(component1: component2, component2: "")
      
      
    // C#T
    case component0Type == ComponentType.callSign && component1Type == ComponentType.numeric && component2Type == ComponentType.text:
      callStructureType = CallStructureType.callDigitText
      setCallSignFlags(component1: component2, component2: "")
      
      
    // CMM
    case component0Type == ComponentType.callSign && component1Type == ComponentType.portable && component2Type == ComponentType.portable:
      callStructureType = CallStructureType.callPortablePortable
      setCallSignFlags(component1: component1, component2: "")
      
      
    // CMP
    case component0Type == ComponentType.callSign && component1Type == ComponentType.portable && component2Type == ComponentType.prefix:
      baseCall = component0
      prefix = component2
      suffix1 = component1
      callStructureType = CallStructureType.callPortablePrefix
      setCallSignFlags(component1: component1, component2: "")
      
      
    // CMT
    case component0Type == ComponentType.callSign && component1Type == ComponentType.portable && component2Type == ComponentType.text:
      callStructureType = CallStructureType.callPortableText
      setCallSignFlags(component1: component1, component2: "")
      return;
      
    // CPM
    case component0Type == ComponentType.callSign && component1Type == ComponentType.prefix && component2Type == ComponentType.portable:
      callStructureType = CallStructureType.callPrefixPortable
      setCallSignFlags(component1: component2, component2: "")
      
      
    // PCM
    case component0Type == ComponentType.prefix && component1Type == ComponentType.callSign && component2Type == ComponentType.portable:
      baseCall = component1
      prefix = component0
      suffix1 = component2
      callStructureType = CallStructureType.prefixCallPortable
      
    // PCT
    case component0Type == ComponentType.prefix && component1Type == ComponentType.callSign && component2Type == ComponentType.text:
      baseCall = component1
      prefix = component0
      suffix1 = component2
      callStructureType = CallStructureType.prefixCallText
      
      // CM#
    case component0Type == ComponentType.callSign && component1Type == ComponentType.portable && component2Type == ComponentType.numeric:
      baseCall = component0
      prefix = component2
      suffix1 = component1
      setCallSignFlags(component1: component2, component2: "")
      callStructureType = CallStructureType.callDigitPortable
      
    default:
      return
    }
  }

  /*/
   Just a quick test for grossly invalid call signs.
   */
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


  /**
   
   */
  mutating func setCallSignFlags(component1: String, component2: String){
    
    switch component1 {
    case "R":
      callSignFlags.append(CallSignFlags.beacon)
      
      case "B":
      callSignFlags.append(CallSignFlags.beacon)
      
    case "P":
      if component2 == "QRP" {
        callSignFlags.append(CallSignFlags.qrp)
      }
      callSignFlags.append(CallSignFlags.portable)
      
      case "QRP":
      if component2 == "P" {
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
  
  /**
   FStructure:= StringReplace(FStructure, 'UU', 'PC', [rfReplaceAll]);
   
    I don't agree with this one
   FStructure:= StringReplace(FStructure, 'CU', 'CP', [rfReplaceAll]);
   
   FStructure:= StringReplace(FStructure, 'UC', 'PC', [rfReplaceAll]);
   FStructure:= StringReplace(FStructure, 'UP', 'CP', [rfReplaceAll]);
   FStructure:= StringReplace(FStructure, 'PU', 'PC', [rfReplaceAll]);
   FStructure:= StringReplace(FStructure, 'U', 'C', [rfReplaceAll]);
   */
  func resolveAmbiguities(componentType0: ComponentType, componentType1: ComponentType, component0Type: inout ComponentType, component1Type: inout ComponentType){
   
    switch true {
    // UU --> PC
    case componentType0 == ComponentType.unknown && componentType1 == ComponentType.unknown:
      component0Type = ComponentType.prefix
      component1Type = ComponentType.callSign
      
    // CU --> CP - I don't agree with this --> CT
    case componentType0 == ComponentType.callSign && componentType1 ==    ComponentType.unknown:
       component0Type = ComponentType.callSign
       component1Type = ComponentType.text
      
    // UC --> PC - I don't agree with this --> TC
    case componentType0 == ComponentType.unknown && componentType1 == ComponentType.callSign:
      component0Type = ComponentType.text
      component1Type = ComponentType.callSign
      
    // UP --> CP
    case componentType0 == ComponentType.unknown && componentType1 == ComponentType.prefix:
      component0Type = ComponentType.callSign
      component1Type = ComponentType.prefix
      
    // PU --> PC
    case componentType0 == ComponentType.prefix && componentType1 == ComponentType.unknown:
      component0Type = ComponentType.prefix
      component1Type = ComponentType.callSign
      
    // U --> C
    case componentType0 == ComponentType.unknown:
      component0Type = ComponentType.callSign
      component1Type = componentType1
      
    // U --> C
    case componentType1 == ComponentType.unknown:
      component1Type = ComponentType.callSign;
      component0Type = componentType0;
      
    default:
      component0Type = ComponentType.unknown
      component1Type = ComponentType.unknown
    }

  }
  
  /**
   one of "@","@@","#@","#@@" followed by 1-4 digits followed by 1-6 letters
   ValidPrefixes = ':@:@@:@@#:@@#@:@#:@#@:@##:#@:#@@:#@#:#@@#:';
   ValidStructures = ':C:C#:C#M:C#T:CM:CM#:CMM:CMP:CMT:CP:CPM:CT:PC:PCM:PCT:';
   */
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


    //let numbersRange = candidate.rangeOfCharacter(from: .decimalDigits)
        //let hasNumbers = (numbersRange != nil)


    //while String(candidate[0]).isInteger {
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
  
  /**
   Test if a candidate is truly a prefix.
   */
  mutating func verifyIfPrefix(candidate: String, position: Int) -> ComponentType {
    
    let validPrefixes = ["@", "@@", "@@#", "@@#@", "@#", "@#@", "@##", "#@", "#@@", "#@#", "#@@#"]
    
    pattern = buildPattern(candidate: candidate)
    
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
  func buildPattern(candidate: String)-> String {
    var pattern = ""
    
    // with 1371294 iterations this is 10 seconds faster than the code below
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

  
  /*
   */
  func isSuffix(candidate: String) -> Bool {
    let validSuffixes = ["A", "B", "M", "P", "MM", "AM", "QRP", "QRPP", "LH", "LGT", "ANT", "WAP", "AAW", "FJL"]
    
    if validSuffixes.contains(candidate){
      return true
    }
    
    return false
  }
  
  /**
   Should this string be considered as text.
   */
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
