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
        prefixData.dxcc_entity  = Int(currentValue ) ?? 0
      case "cq_zone":
        prefixData.cq_zone  = prefixData.buildZoneList(zones: currentValue )
      case "itu_zone":
        prefixData.itu_zone  = prefixData.buildZoneList(zones: currentValue )
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
      for currentValue in prefixData.tempMaskList {
        let primaryMaskList = expandMask(element: currentValue)

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

// https://stackoverflow.com/questions/31083348/parsing-xml-from-url-in-swift/31084545#31084545
//extension QRZManager: XMLParserDelegate {
//
//  //let logger = Logger(subsystem: "com.w6op.xCluster", category: "Controller")
//  // initialize results structure
//  func parserDidStartDocument(_ parser: XMLParser) {
//    //logger.info("Parsing started.")
//    results = []
//    callSignLookup = ["call": "", "country": "", "lat": "", "lon": "", "grid": "", "lotw": "0", "aliases": "", "Error": ""]//[String: String]()
//  }
//
//  // start element
//  //
//  // - If we're starting a "Session" create the dictionary that will hold the results
//  // - If we're starting one of our dictionary keys, initialize `currentValue` (otherwise leave `nil`)
//  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
//
//    switch elementName {
//    case KeyName.sessionKeyName.rawValue:
//      if sessionKey == nil {
//        sessionLookup = ["Key": "", "Count": "", "SubExp": "", "GMTime": "", "Remark": ""]//[:]
//      } else {
//        //print("didStartElement: \(elementName)")
//      }
//    case KeyName.recordKeyName.rawValue:
//      callSignLookup = ["call": "", "country": "", "lat": "", "lon": "", "grid": "", "lotw": "0", "aliases": "", "Error": ""] //[:]
//    case KeyName.errorKeyName.rawValue:
//      //logger.info("Parser error: \(elementName):\(self.currentValue)")
//      break
//    default:
//      if currentValue.condenseWhitespace() != "" {
//        logger.info("didStartElement default hit: \(self.currentValue.condenseWhitespace())")
//        //print("default hit: \(currentValue.condenseWhitespace())")
//      }
//    }
//  }
//
//  // found characters
//  //
//  // - If this is an element we care about, append those characters.
//  // - If `currentValue` still `nil`, then do nothing.
//  func parser(_ parser: XMLParser, foundCharacters string: String) {
//    currentValue += string
//  }
//
//  // end element
//  //
//  // - If we're at the end of the whole dictionary, then save that dictionary in our array
//  // - If we're at the end of an element that belongs in the dictionary, then save that value in the dictionary
//  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
//
//    switch elementName {
//    case KeyName.sessionKeyName.rawValue:
//      // don't seem to need this
//      //print("Here 2s - was this an error? \(elementName)")
//      break
//    case KeyName.recordKeyName.rawValue:
//      results!.append(callSignLookup)
//    case KeyName.errorKeyName.rawValue:
//      //logger.info("didEndElement Error: \(self.currentValue)")
//      callSignLookup = ["call": "", "country": "", "lat": "", "lon": "", "grid": "", "lotw": "0", "aliases": "", "Error": ""]//[:]
//      callSignLookup[elementName] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
//      if currentValue.contains("Session Timeout") {
//        // abort this and request a session key
//        logger.info("Session Timed Out - abort processing")
//        isSessionKeyValid = false
//        parser.abortParsing()
//      }
//    default:
//      // if callSignDictionaryKeys.contains(elementName) {
//      if callSignLookup.keys.contains(elementName) {
//        callSignLookup[elementName] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
//      } else if sessionLookup.keys.contains(elementName) {
//        sessionLookup[elementName] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
//      }
//      currentValue = ""
//    }
//  }
//
//  func parserDidEndDocument(_ parser: XMLParser) {
//    //logger.info("Parsing completed.")
//  }
//
//  // Just in case, if there's an error, report it. (We don't want to fly blind here.)
//  func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
//    logger.info("parser failed: \(parseError as NSObject)")
//    currentValue = ""
//
//    if !isSessionKeyValid {
//      logger.info("Request a new Session Key")
//      requestSessionKey(name: qrzUserName, password: qrzPassword)
//    }
//  }
//}
