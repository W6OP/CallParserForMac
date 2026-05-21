//
//  CallParserCommon.swift
//  CallParser
//
//  Created by Peter Bourget on 6/13/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation

// MARK: - Benchmark Data Sets

/// Bundled CSV files available for batch lookup benchmarks.
public enum BenchmarkDataSet: String, CaseIterable, Sendable {
  case compound
  case pskreporter

  /// Display label for UI pickers.
  public var label: String {
    switch self {
    case .compound: "compound.csv"
    case .pskreporter: "pskreporter.csv"
    }
  }

  /// The bundle resource name (without extension).
  public var resourceName: String { rawValue }
}

// MARK: - Parsed Prefix Data

/// Immutable snapshot of the prefix data produced by ``PrefixFileParser``.
///
/// Holding the parsed tables in a value-type ``Sendable`` container lets
/// ``CallLookup`` be fully `Sendable` without `@unchecked`, and avoids
/// passing a non-`Sendable` parser instance across actor boundaries.
public struct ParsedPrefixData: Sendable {
  public let callSignPatterns: [String: [PrefixData]]
  public let portablePrefixPatterns: [String: [PrefixData]]
  public let adifs: [Int: PrefixData]
  /// Prototype bitset-based mask index. Empty for callers that haven't
  /// supplied one (e.g. the deprecated convenience initializers).
  public let bitsetIndex: BitsetMaskIndex

  public init(
    callSignPatterns: [String: [PrefixData]],
    portablePrefixPatterns: [String: [PrefixData]],
    adifs: [Int: PrefixData],
    bitsetIndex: BitsetMaskIndex = BitsetMaskIndex()
  ) {
    self.callSignPatterns = callSignPatterns
    self.portablePrefixPatterns = portablePrefixPatterns
    self.adifs = adifs
    self.bitsetIndex = bitsetIndex
  }
}

// MARK: - QRZManager Protocol

public enum KeyName: String {
  case errorKeyName = "Error"
  case sessionKeyName = "Session"
  case recordKeyName = "Callsign"
}

//public enum QRZMessages: String {
//  case sessionTimeout = "Session Timeout"
//  case connectionRefused = "Connection refused"
//  case invalidCredentials = "Username/password incorrect"
//  case unknownError = "Unknown error"
//}

public enum QRZManagerError: Error {
  case sessionKeyAvailable
  case sessionTimeout
  case requestTooFrequent
  case invalidCredentials
  case lockout
  case notFound
  case unknown
}

enum CharacterType: String {
  case numeric = "#"
  case alphabetical = "@"
  case alphanumeric = "?"
  case alphaNumericCombined = "@#"
  case numericAlphaCombined = "#@"
  case dash = "-"
  case stopIndicator = "."
  case portableIndicator = "/"
  case empty = ""
}

// MARK: - PrefixKind Enum ----------------------------------------------------------------------------
// - Updated for V6
public enum PrefixKind:  String, Sendable {
  case none = "pfNone"
  case dXCC = "pfDXCC"
  case province = "pfProvince"
  case station = "pfStation"
  case delDXCC = "pfDelDXCC"
  case oldPrefix = "pfOldPrefix"
  case nonDXCC = "pfNonDXCC"
  case invalidPrefix = "pfInvalidPrefix"
  case delProvince = "pfDelProvince"
  case city = "pfCity"
}

// MARK: - CallSignFlags Enum ----------------------------------------------------------------------------
// - Updated for V6
public enum CallSignFlags:  String, Sendable {
  case none = "cfNone"
  case invalid = "cfInvalid"
  case maritime = "cfMaritime"
  case portable = "cfPortable"
  case special = "cfSpecial"
  case club = "cfClub"
  case beacon = "cfBeacon"
  case lotw = "cfLotw"
  case ambigPrefix = "cfAmbigPrefix"
  case qrp = "cfQrp"
}

// MARK: - Valid Structures Enum ----------------------------------------------------------------------------

/**
 ValidStructures = ':C:C#:C#M:C#T:CM:CM#:CMM:CMP:CMT:CP:CPM:CT:PC:PCM:PCT:';
 */

/// Types of CallStructures defined.
public enum CallStructureType: String {
  case call = "C"
  case callDigit = "C#"
  case callDigitPortable = "C#M"
  case callDigitText = "C#T"
  case callPortable = "CM"
  case callPortableDigit = "CM#"
  case callPortablePortable = "CMM"
  case callPortablePrefix = "CMP"
  case callPortableText = "CMT"
  case callPrefix = "CP"
  case callPrefixPortable = "CPM"
  case callText = "CT"
  case prefixCall = "PC"
  case prefixCallPortable = "PCM"
  case prefixCallText = "PCT"
  case invalid = "Invalid"
}

/// Types of strings.
enum StringTypes: String {
  case numeric
  case text
  case invalid
  case valid
}

/// Types of call sign components.
enum ComponentType {
  case callSign
  case callOrPrefix
  case prefix
  case text
  case numeric
  case portable
  case unknown
  case invalid
  case valid
}

// EndingPreserve = ':R:P:M:';
// EndingIgnore = ':AM:MM:QRP:A:B:BCN:LH:';

/// Types of call sign suffixes.
public enum CallSignType: String {
  case a = "A"
  case adif = "ADIF"
  case b = "B"
  case bcn = "Beacon"
  case lh = "LH"
  case m = "Mobile"
  case mm = "Marine Mobile"
  case p = "Portable"
  case qrp = "Low Power"
  case r = "Rover"
}

/// Cases to search by.
enum SearchBy: String {
  case prefix
  case call
  case none
}
