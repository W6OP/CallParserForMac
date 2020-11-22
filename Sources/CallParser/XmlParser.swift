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
@available(OSX 10.14, *)
extension PrefixFileParser: XMLParserDelegate {
  /**
   Initialize data structures on start
   - parameters:
   - parser: XmlParser
   */
  public func parserDidStartDocument(_ parser: XMLParser) {
    // array of array of prefixData (CallSignInfo)
    //prefixList = [PrefixData]()
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
    } else if elementName == "Error" {
      print(elementName)
    }
    //print(elementName)
  }
  /**
   Getting the value of each element. This differs from the C# version
   as I pass in the entire prefix node to the CallSignInfo (PrefixData)
   class and let it parse it. I can't do that easily in Swift.
   - parameters:
   -
   */
  public func parser(_ parser: XMLParser, foundCharacters string: String) {
   
    let currentValue = string.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    
    if (!currentValue.isEmpty) {
      switch (nodeName){
      case "mask":
          prefixData.tempMaskList.append(currentValue)
//        expandedMaskList = expandMask(element: currentValue)
//        prefixData.setPrimaryMaskList(value: expandedMaskList)
//        buildPattern(primaryMaskList: expandedMaskList)
      case "label":
        prefixData.fullPrefix = currentValue
        prefixData.setMainPrefix(fullPrefix: currentValue )
      case "kind":
        prefixData.setPrefixKind(prefixKind: PrefixKind(rawValue: currentValue )!)
      case "country":
        prefixData.country  = currentValue
      case "province":
        prefixData.province  = currentValue
      case "dxcc_entity":
        prefixData.dxcc  = Int(currentValue ) ?? 0
      case "cq_zone":
        prefixData.cq  = prefixData.buildZoneList(zones: currentValue )
      case "itu_zone":
        prefixData.itu  = prefixData.buildZoneList(zones: currentValue )
      case "continent":
        prefixData.continent  = currentValue
      case "time_zone":
        prefixData.timeZone  = currentValue
      case "lat":
        prefixData.latitude  = currentValue
      case "long":
        prefixData.longitude  = currentValue
      case "city":
        prefixData.city = currentValue
      case "wap_entity":
        prefixData.wap = currentValue
      case "wae_entity":
        prefixData.wae = Int(currentValue ) ?? 0
      case "province_id":
        prefixData.admin1 = currentValue
      case "start_date":
        prefixData.startDate = currentValue
      case "end_date":
        prefixData.endDate = currentValue
      case .none:
        break
      case .some(_):
        break
      }
    }
  }
  
  /**
   At the end of each prefix element save the value
   - parameters:
   -
   */
  public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
   
    if elementName == recordKey {
      
      if prefixData.kind == PrefixKind.dXCC {
        let key = Int(prefixData.dxcc)
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
      for currentValue in prefixData.tempMaskList {
        let expandedMaskList = expandMask(element: currentValue)
        prefixData.setPrimaryMaskList(value: expandedMaskList)
        buildMaskPattern(primaryMaskList: expandedMaskList)
      }
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
