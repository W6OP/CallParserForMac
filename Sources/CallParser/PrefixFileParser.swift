//
//  PrefixFileParser.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation

// MARK: - CallParser Class ----------------------------------------------------------------------------

public final class PrefixFileParser: NSObject {

  var bitsetIndex = BitsetMaskIndex()
  var adifs = [Int: PrefixData]()
  /// Shape patterns of every registered portable mask (those ending in `/`).
  /// Used by ``CallStructure`` to decide whether a 2-or-more-character
  /// alpha/digit sequence should be treated as a known portable prefix.
  var portablePrefixShapePatterns = Set<String>()

  let recordKey = "prefix"
  let errorKey = "Error"

  var prefixData = PrefixData()
  var nodeName: String?
  var currentValue: String?

  /// Parses the bundled `PrefixList.xml` and returns an immutable, `Sendable`
  /// snapshot suitable for handing directly to ``CallLookup``.
  public static func parse() -> ParsedPrefixData {
    let parser = PrefixFileParser()
    return ParsedPrefixData(
      adifs: parser.adifs,
      bitsetIndex: parser.bitsetIndex,
      portablePrefixShapePatterns: parser.portablePrefixShapePatterns
    )
  }

  /// Use ``parse()``.
  public override init() {
    super.init()
    parsePrefixFile()
  }

  /// Start parsing the embedded XML file.
  public func parsePrefixFile() {
    guard let url = Bundle.module.url(forResource: "PrefixList", withExtension: "xml") else {
      print("Invalid prefix file: ")
      return
    }

    guard let parser = XMLParser(contentsOf: url) else {
      print("Parser init failed: ")
      return
    }

    parser.delegate = self
    _ = parser.parse()
  }
}
