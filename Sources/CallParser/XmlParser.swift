//
//  XmlParser.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

import Foundation

// https://stackoverflow.com/questions/31083348/parsing-xml-from-url-in-swift/31084545#31084545
// https://www.ioscreator.com/tutorials/parse-xml-ios-tutorial
extension PrefixFileParser: XMLParserDelegate {

  /**
   Initialize data structures on start
   - parameters:
   - parser: XmlParser
   */
  public func parserDidStartDocument(_ parser: XMLParser) {
    print("document started")
  }
  /**
   Initialize PrefixData each time we make a pass. This is called each
   time a new prefix element is found
   - parameters:
   -
   */
  public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
    currentValue = ""
    nodeName = elementName
    if elementName == recordKey {
      prefixData = PrefixData()
      tempMaskList = [String]()
    } else if elementName == errorKey {
      print(elementName)
    }
  }

  /// Accumulate the raw text for the current element. Foundation's
  /// `XMLParser` can deliver a single text node across multiple
  /// `foundCharacters` callbacks (e.g. either side of an entity reference
  /// like `&amp;`), so we must append rather than overwrite. The field
  /// assignment happens once, in `didEndElement`.
  public func parser(_ parser: XMLParser, foundCharacters literal: String) {
    currentValue = (currentValue ?? "") + literal
  }

  /**
   At the end of each element commit the accumulated value to the right
   field. The record-level commit still runs only when we finish a
   `<prefix>` element.
   */
  public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {

    let value = (currentValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if !value.isEmpty {
      switch elementName {
      case "mask":
        prefixData.tempMaskList.append(value)
      case "label":
        prefixData.fullPrefix = value
        prefixData.setMainPrefix(fullPrefix: value)
      case "kind":
        if let kind = PrefixKind(rawValue: value) {
          prefixData.setPrefixKind(prefixKind: kind)
        }
      case "country":
        prefixData.country = value
      case "province":
        prefixData.province = value
      case "dxcc_entity":
        prefixData.dxcc_entity = Int(value) ?? 0
      case "cq_zone":
        prefixData.cq_zone = prefixData.buildZoneList(zones: value)
      case "itu_zone":
        prefixData.itu_zone = prefixData.buildZoneList(zones: value)
      case "continent":
        prefixData.continent = value
      case "time_zone":
        prefixData.timeZone = value
      case "lat":
        prefixData.latitude = value
      case "long":
        prefixData.longitude = value
      case "city":
        prefixData.city = value
      case "wap_entity":
        prefixData.wap = value
      case "wae_entity":
        prefixData.wae = Int(value) ?? 0
      case "province_id":
        prefixData.admin1 = value
      case "start_date":
        prefixData.startDate = value
      case "end_date":
        prefixData.endDate = value
      default:
        break
      }
    }

    currentValue = nil
    nodeName = nil

    if elementName == recordKey {

      if prefixData.kind == PrefixKind.dXCC {
        let key = Int(prefixData.dxcc_entity)
        adifs[key] = prefixData
      }

      if prefixData.kind == PrefixKind.invalidPrefix {
        adifs[0] = prefixData
      }

      if prefixData.wae != 0 {
        adifs[prefixData.wae] = prefixData
      }

      if prefixData.kind == PrefixKind.province && prefixData.admin1 == "" {

        if var valueExists = admins[prefixData.admin1] {
          valueExists.append(prefixData)
        } else {
          admins[prefixData.admin1] = [PrefixData](arrayLiteral: prefixData)
        }
      }

      // NEED TO PRESERVE THE callSignPatterns and portablePrefixPatterns
      // until this element is complete and then put the same prefixData
      // in all of them - works in C# because everything is byRef
      var patterns = [String]()
      for mask in prefixData.tempMaskList {
        let primaryMaskList = expandMask(element: mask)

        prefixData.setPrimaryMaskList(value: primaryMaskList)

        let patternList = buildMaskPattern(primaryMaskList: primaryMaskList)
        patterns.append(contentsOf: patternList)
      }
      savePatternList(patternList: patterns, prefixData: prefixData)
    }
  }
  
  /**
   Parsing has finished
   - parameters:
   -
   */
  public func parserDidEndDocument(_ parser: XMLParser) {
    print("document finished")
  }
  
  /**
   Just in case, if there's an error, report it.
   - parameters:
   -
   */
  public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
    print(parseError)
    currentValue = ""
  }
}
