////
////  QRZManager.swift
////  xCluster
////
////  Created by Peter Bourget on 7/8/20.
////  Copyright © 2020 Peter Bourget. All rights reserved.
////
//
import Cocoa
import Network
import CoreLocation
import os

// MARK: - QRZManager Protocol

protocol QRZManagerDelegate: AnyObject {
  func qrzManagerDidGetSessionKey(_ qrzManager: QRZManager,
                                  messageKey: QRZManagerMessage,
                                  doHaveSessionKey: Bool)
  func qrzManagerDidGetCallSignData(_ qrzManager: QRZManager,
                                    messageKey: QRZManagerMessage, call: String)
}

public enum KeyName: String {
  case errorKeyName = "Error"
  case sessionKeyName = "Session"
  case recordKeyName = "Callsign"
}

public enum QRZManagerMessage: String {
  case session = "Session key available"
  case qrzInformation = "Call sign information"
}

// MARK: QRZManager Implementation

public class QRZManager: NSObject {

  private let stationProcessorQueue =
  DispatchQueue(
    label: "com.w6op.virtualcluster.qrzProcessorQueue")

  // MARK: - Field Definitions

  let logger = Logger(subsystem: "com.w6op.CallParser", category: "QRZManager")

  // delegate to pass messages back to view
  weak var qrZedManagerDelegate: QRZManagerDelegate?

  var sessionKey: String!
  var isSessionKeyValid: Bool = false

  var qrzUserName = ""
  var qrzPassword = ""
  var useCallLookupOnly = false

  let callSignDictionaryKeys = Set<String>(["call", "country", "lat",
                                            "lon", "grid", "lotw",
                                            "aliases", "Error"])
  let sessionDictionaryKeys = Set<String>(["Key", "Count", "SubExp",
                                           "GMTime", "Remark"])
  var results: [[String: String]]?         // the whole array of dictionaries
  var sessionDictionary: [String: String]! // the current session dictionary
  var callSignDictionary: [String: String]! // array of key/value pairs
  var currentValue = ""
  var locationDictionary: (spotter: [String: String], dx: [String: String])!

  //  // MARK: - Initialization
  //
  override init() {
    super.init()
  }

  // MARK: - Network Implementation

  //  /// Get a Session Key from QRZ.com.
  //  /// - Parameters:
  //  ///   - name: String
  //  ///   - password: String
  func requestSessionKey(userId: String, password: String) {

    logger.info("Request Session Key.")

    qrzUserName = userId
    qrzPassword = password

    sessionDictionary = ["Key": "", "Count": "", "SubExp": "",
                         "GMTime": "", "Remark": ""]

    guard let url = URL(string: "https://xmldata.qrz.com/xml/current/?username=\(userId);password=\(password);CallParser=1.2") else {
      logger.info("Invalid user name or password: \(userId)")
      return
    }

    let task = URLSession.shared.dataTask(with: url) { [self] data,
      response, error in
      if let error = error {
        fatalError("Error: \(error.localizedDescription)")
      }

      guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else {
        fatalError("Error: invalid HTTP response code")
      }

      guard let data = data else {
        fatalError("Error: missing response data")
      }

      let parser = XMLParser(data: data)
      parser.delegate = self

      if parser.parse() {
        if self.results != nil {
          logger.info("Session Key Retrieved.")
          sessionKey = self.sessionDictionary["Key"]
          isSessionKeyValid = true
          qrZedManagerDelegate?.qrzManagerDidGetSessionKey(
            self, messageKey: .session, doHaveSessionKey: true)
        }
      }
    }
    task.resume()
  }


  /// Request the callsign data from QRZ.com
  /// - Parameter call: String
  func requestQRZInformation(call: String) async throws {

    if isSessionKeyValid == false {
      requestSessionKey(userId: qrzUserName, password: qrzPassword)
      // throw?
    }

    // this dies if session key is missing
    guard let url = URL(string: "https://xmldata.qrz.com/xml/current/?s=\(String(self.sessionKey));callsign=\(call)")
    else {
      logger.info("Session key is invalid: \(self.sessionKey)")
      return
    }

    let (data, response) = try await
    URLSession.shared.data(from: url)

    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      print("The server responded with an error")
      return
    }

    parseReceivedData(data: data, call: call)
  }

  /// Pass the received data to the parser.
  /// - Parameters:
  ///   - data: Data
  ///   - call: String
  fileprivate func parseReceivedData(data: Data, call: String) {

    //if you need to look at xml input for debugging
    //let str = String(decoding: data, as: UTF8.self)
    //print(str)

    stationProcessorQueue.async { [self] in
      let parser = XMLParser(data: data)
      parser.delegate = self

      if parser.parse() {
        if self.results != nil {
          self.qrZedManagerDelegate?.qrzManagerDidGetCallSignData(
            self, messageKey: .qrzInformation, call: call)
        } else {
          logger.info("Use CallParser: (0) \(call)")
        }
      }
    }
  }
} // end class


// https://stackoverflow.com/questions/31083348/parsing-xml-from-url-in-swift/31084545#31084545
extension QRZManager: XMLParserDelegate {

  //let logger = Logger(subsystem: "com.w6op.xCluster", category: "Controller")
  // initialize results structure
  public func parserDidStartDocument(_ parser: XMLParser) {
    //logger.info("Parsing started.")
    results = []
    callSignDictionary = [String: String]()
  }

  // start element
  //
  // - If we're starting a "Session" create the dictionary that will hold the results
  // - If we're starting one of our dictionary keys, initialize `currentValue` (otherwise leave `nil`)
  public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {

    switch elementName {
    case KeyName.sessionKeyName.rawValue:
      if sessionKey == nil {
        sessionDictionary = [:]
      } else {
        //print("didStartElement: \(elementName)")
      }
    case KeyName.recordKeyName.rawValue:
      callSignDictionary = [:]
    case KeyName.errorKeyName.rawValue:
      //logger.info("Parser error: \(elementName):\(self.currentValue)")
      break
    default:
      if callSignDictionaryKeys.contains(elementName) {
        currentValue = ""
      }
    }
  }

  // found characters
  //
  // - If this is an element we care about, append those characters.
  // - If `currentValue` still `nil`, then do nothing.
  public func parser(_ parser: XMLParser, foundCharacters string: String) {
    currentValue += string
  }

  // end element
  //
  // - If we're at the end of the whole dictionary, then save that dictionary in our array
  // - If we're at the end of an element that belongs in the dictionary, then save that value in the dictionary
  public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {

    switch elementName {
    case KeyName.sessionKeyName.rawValue:
      // don't seem to need this
      //print("Here 2s - was this an error? \(elementName)")
      break
    case KeyName.recordKeyName.rawValue:
      results!.append(callSignDictionary!)
    case KeyName.errorKeyName.rawValue:
      //logger.info("didEndElement Error: \(self.currentValue)")
      callSignDictionary = [:]
      callSignDictionary[elementName] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if currentValue.contains("Session Timeout") {
        // abort this and request a session key
        logger.info("Session Timed Out - abort processing")
        isSessionKeyValid = false
        parser.abortParsing()
      }
    default:
      if callSignDictionaryKeys.contains(elementName) {
        callSignDictionary[elementName] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
      } else if sessionDictionaryKeys.contains(elementName) {
        sessionDictionary[elementName] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      currentValue = ""
    }
  }

  public func parserDidEndDocument(_ parser: XMLParser) {
    //logger.info("Parsing completed.")
  }

  // Just in case, if there's an error, report it. (We don't want to fly blind here.)
  public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
    logger.info("parser failed: \(parseError as NSObject)")
    currentValue = ""

    if !isSessionKeyValid {
      logger.info("Request a new Session Key")
      requestSessionKey(userId: qrzUserName, password: qrzPassword)
    }
  }
}



/*
 <?xml version="1.0" encoding="utf-8" ?>
 <QRZDatabase version="1.34" xmlns="http://xmldata.qrz.com">
 <Callsign>
 <call>W6OP</call>
 <aliases>WA6YUL</aliases>
 <dxcc>291</dxcc>
 <fname>Peter H</fname>
 <name>Bourget</name>
 <addr1>3422 Five Mile Dr</addr1>
 <addr2>Stockton</addr2>
 <state>CA</state>
 <zip>95219</zip>
 <country>United States</country>
 <lat>38.010872</lat>
 <lon>-121.355854</lon>
 <grid>CM98ha</grid>
 <county>San Joaquin</county>
 <ccode>271</ccode>
 <fips>06077</fips>
 <land>United States</land>
 <efdate>2015-03-14</efdate>
 <expdate>2025-05-20</expdate>
 <class>E</class>
 <codes>HVIE</codes>
 <qslmgr>DIRECT: SAE OR LOTW OR BUREAU</qslmgr>
 <email>pbourget@w6op.com</email>
 <u_views>9481</u_views>
 <bio>1800</bio>
 <biodate>2015-07-16 00:32:36</biodate>
 <image>https://cdn-xml.qrz.com/p/w6op/w6op.jpg</image>
 <imageinfo>300:400:48591</imageinfo>
 <moddate>2019-04-17 18:15:56</moddate>
 <MSA>8120</MSA>
 <AreaCode>209</AreaCode>
 <TimeZone>Pacific</TimeZone>
 <GMTOffset>-8</GMTOffset>
 <DST>Y</DST>
 <eqsl>0</eqsl>
 <mqsl>1</mqsl>
 <cqzone>3</cqzone>
 <ituzone>6</ituzone>
 <lotw>1</lotw>
 <user>W6OP</user>
 <geoloc>user</geoloc>
 <name_fmt>Peter H Bourget</name_fmt>
 </Callsign>
 <Session>
 <Key>74e3927011e51163888deff1f0e244d0</Key>
 <Count>9772334</Count>
 <SubExp>Thu Dec 29 00:00:00 2022</SubExp>
 <GMTime>Wed Dec 22 22:37:39 2021</GMTime>
 <Remark>cpu: 0.019s</Remark>
 </Session>
 </QRZDatabase>
 */
