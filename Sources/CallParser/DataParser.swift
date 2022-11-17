//
//  File.swift
//  
//
//  Created by Peter Bourget on 11/17/22.
//

import Foundation
import os

/// Unify message nouns going to the view controller
enum NetworkMessage: String {
  case call = "call"
  case dxcc = "dxcc"
  case state = "state"
  case country = "country"
  case lat = "lat"
  case lon = "lon"
  case grid = "grid"
  case county = "county"
  case Session = "Session"
  case Key = "Key"
  case Error = "Error"
}

/// Web Manager Protocol
protocol DataParserDelegate: AnyObject {
  func connect(isReconnection: Bool)
  func dataParserDataReceived(_ webManager: DataParser,
                              messageKey: NetworkMessage,
                              message: String)
}

class DataParser {

  // delegate to pass messages back to call parser
  weak var dataParserDelegate: DataParserDelegate?

  /// Unify message nouns going to the view controller
  // TODO: this is wrong
  enum NetworkMessage: String {
    case call = "call"
    case dxcc = "dxcc"
    case state = "state"
    case country = "country"
    case lat = "lat"
    case lon = "lon"
    case grid = "grid"
    case county = "county"
    case Session = "Session"
    case Key = "Key"
    case Error = "Error"
  }

  enum MessageContent {
    static let call = "<call>"
    static let country = "<country>"
    static let dxcc = "<dxcc>"
    static let addr2 = "<addr2>"
    static let county = "<county>"
    static let state = "<state>"
    static let lat = "<lat>"
    static let lon = "<lon>"
    static let grid = "<grid>"
    static let lotw = "<lotw>"
    static let aliases = "<aliases>"
    static let error = "<Error> "
    static let key = "<Key>"
    static let count = "<Count>"
    static let subExp = "<SubExp"
    static let gmTime = "<GMTime>"
    static let remark = "<Remark>"
    static let xmlHeader = "<?xml version"
    static let session = "<Session>"
  }

  init() {

  }

  // take the session xml and populate the sessionDictionary
  // first look for the Session line or should I look for Error first?
  // then loop through and finish
  func parseSessionData(html: String) async -> [String : String] {
    var sessionDictionary =  [String: String]()

    if html.contains(MessageContent.xmlHeader) {
      let lines = html.split(whereSeparator: \.isNewline)
      for line in lines where !line.isEmpty {
        let trimmedline = line.trimmingCharacters(in: .whitespaces)
        populateSessionDictionary(line: String(trimmedline), sessionDictionary: &sessionDictionary)
      }
    }

    return sessionDictionary
  }

  func populateSessionDictionary(line: String, sessionDictionary: inout [String : String])  {

    switch line {
    case _ where line.contains(MessageContent.key):
      sessionDictionary["Key"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.count):
      sessionDictionary["Count"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.subExp):
      sessionDictionary["SubExp"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.gmTime):
      sessionDictionary["GMTime"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.remark):
      sessionDictionary["Remark"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.error):
      sessionDictionary["Error"] = stripXmlTags(line: line)
    default:
      break
    }
  }

  //func parseReceivedData(html: String) async -> [String : String] {
  func parseReceivedData(html: String,
                         spotInformation: (spotId: Int, sequence: Int))
                          -> ([String : String],
                              (spotId: Int, sequence: Int)) {

    var callSignDictionary =  [String: String]()

    if html.contains(MessageContent.xmlHeader) {
      let lines = html.split(whereSeparator: \.isNewline)
      for line in lines where !line.isEmpty {
        let trimmedline = line.trimmingCharacters(in: .whitespaces)
        populateCallSignDictionary(line: String(trimmedline), callSignDictionary: &callSignDictionary)
      }
    }

    return (callSignDictionary, spotInformation)
  }

  func populateCallSignDictionary(line: String, callSignDictionary: inout [String : String])  {

    switch line {
    case _ where line.contains(MessageContent.call):
      callSignDictionary["call"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.country):
      callSignDictionary["country"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.dxcc):
      callSignDictionary["dxcc"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.addr2):
      callSignDictionary["addr2"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.county):
      callSignDictionary["county"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.state):
      callSignDictionary["state"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.lat):
      callSignDictionary["lat"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.lon):
      callSignDictionary["lon"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.grid):
      callSignDictionary["grid"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.lotw):
      callSignDictionary["lotw"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.aliases):
      callSignDictionary["aliases"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.error):
      callSignDictionary["Error"] = stripXmlTags(line: line)
    default:
      break
    }
  }

  func stripXmlTags(line: String) -> String {
    let start = line.firstIndex(of: ">")
    let startIndex = line.index(after: start!)
    let end = line.lastIndex(of: "<")
    let endIndex = line.index(before: end!)
    let range = startIndex...endIndex
    return String(line[range])
  }


} // end class

/*
 <QRZDatabase version="1.36" xmlns="http://xmldata.qrz.com">
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
     <u_views>9683</u_views>
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
     <geoloc>user</geoloc>
     <name_fmt>Peter H Bourget</name_fmt>
   </Callsign>
   <Session>
     <Key>3968bd6f858b6c6a7c92fd7252f8af6f</Key>
     <Count>10047905</Count>
     <SubExp>Thu Dec 29 00:00:00 2022</SubExp>
     <GMTime>Tue May 17 14:38:19 2022</GMTime>
     <Remark>cpu: 0.019s</Remark>
   </Session>
 </QRZDatabase>

 <?xml version=\"1.0\" encoding=\"utf-8\" ?>
 <QRZDatabase version=\"1.36\" xmlns=\"http://xmldata.qrz.com\">
   <Session>
   <Error>Username/password incorrect </Error>
   <GMTime>Thu Nov 17 22:01:26 2022</GMTime>
   <Remark>cpu: 0.025s</Remark>\n</Session>
 </QRZDatabase>

 <?xml version=\"1.0\" encoding=\"utf-8\" ?>
 <QRZDatabase version=\"1.36\" xmlns=\"http://xmldata.qrz.com\">
   <Session>
     <Key>7155f6f2def011f9e330a0201159d8d2</Key>
     <Count>13500028</Count>
     <SubExp>Thu Dec 29 00:00:00 2022</SubExp>
     <GMTime>Thu Nov 17 22:14:35 2022</GMTime>
     <Remark>cpu: 0.086s</Remark>
   </Session>
 </QRZDatabase>
 */
