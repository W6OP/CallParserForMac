//
//  XmlParser.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation

// https://stackoverflow.com/questions/31083348/parsing-xml-from-url-in-swift/31084545#31084545
extension PrefixFileParser: XMLParserDelegate {

  public func parserDidStartDocument(_ parser: XMLParser) {
    print("document started")
  }

  public func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    currentValue = ""
    nodeName = elementName
    if elementName == recordKey {
      prefixData = PrefixData()
    } else if elementName == errorKey {
      print(elementName)
    }
  }

  /// Accumulate the raw text for the current element. Foundation's
  /// `XMLParser` can deliver a single text node across multiple
  /// `foundCharacters` callbacks (e.g. either side of an entity reference
  /// like `&amp;`), so we must append rather than overwrite.
  public func parser(_ parser: XMLParser, foundCharacters literal: String) {
    currentValue = (currentValue ?? "") + literal
  }

  /// At the end of each element commit the accumulated value to the right
  /// field. The record-level commit runs only when a `<prefix>` element ends.
  public func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let value = (currentValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if !value.isEmpty {
      switch elementName {
      case "mask":         prefixData.tempMaskList.append(value)
      case "label":        prefixData.fullPrefix = value
                           prefixData.setMainPrefix(fullPrefix: value)
      case "kind":
        if let kind = PrefixKind(rawValue: value) {
          prefixData.setPrefixKind(prefixKind: kind)
        }
      case "country":      prefixData.country = value
      case "province":     prefixData.province = value
      case "dxcc_entity":  prefixData.dxcc_entity = Int(value) ?? 0
      case "cq_zone":      prefixData.cq_zone = prefixData.buildZoneList(zones: value)
      case "itu_zone":     prefixData.itu_zone = prefixData.buildZoneList(zones: value)
      case "continent":    prefixData.continent = value
      case "time_zone":    prefixData.timeZone = value
      case "lat":          prefixData.latitude = value
      case "long":         prefixData.longitude = value
      case "city":         prefixData.city = value
      case "wap_entity":   prefixData.wap = value
      case "wae_entity":   prefixData.wae = Int(value) ?? 0
      case "province_id":  prefixData.admin1 = value
      case "start_date":   prefixData.startDate = value
      case "end_date":     prefixData.endDate = value
      default: break
      }
    }

    currentValue = nil
    nodeName = nil

    guard elementName == recordKey else { return }

    if prefixData.kind == .dXCC {
      adifs[Int(prefixData.dxcc_entity)] = prefixData
    }
    if prefixData.kind == .invalidPrefix {
      adifs[0] = prefixData
    }
    if prefixData.wae != 0 {
      adifs[prefixData.wae] = prefixData
    }

    // Compile every mask into the bitset index. Skip invalid-prefix records
    // so the buckets only contain real matches.
    guard prefixData.kind != .invalidPrefix else { return }
    for mask in prefixData.tempMaskList {
      guard let compiled = MaskBitset.compile(mask) else { continue }
      bitsetIndex.insert(compiled, data: prefixData)
      if compiled.endsWithPortable {
        portablePrefixShapePatterns.insert(compiled.shapePattern)
      }
    }
  }

  public func parserDidEndDocument(_ parser: XMLParser) {
    print("document finished")
  }

  public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
    print(parseError)
    currentValue = ""
  }
}
