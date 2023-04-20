//
//  File.swift
//  
//
//  Created by Peter Bourget on 11/17/22.
//

import Foundation
import os

class DataParser {

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
    static let error = "<Error>"
    static let key = "<Key>"
    static let count = "<Count>"
    static let subExp = "<SubExp"
    static let gmTime = "<GMTime>"
    static let remark = "<Remark>"
    static let message = "<Message>"
    static let xmlHeader = "<?xml version"
    static let session = "<Session>"
  }

  init() {}

  /*
   html  String  "<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n<QRZDatabase version=\"1.36\" xmlns=\"http://xmldata.qrz.com\">\n<Session>\n<Error>Username/password incorrect </Error>\n<GMTime>Sat Jan 21 15:40:35 2023</GMTime>\n<Remark>cpu: 0.032s</Remark>\n</Session>\n</QRZDatabase>\n"
   */

  
  /// Take the session xml and populate the sessionDictionary.
  /// - Parameter html: String
  /// - Returns: [String : String]
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

  ///  /// Populate the session sign dictionary with the values from the returned xml.
  /// - Parameters:
  ///   - line: String
  ///   - sessionDictionary: [String : String]
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
    case _ where line.contains(MessageContent.message):
      sessionDictionary["Message"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.error):
      sessionDictionary["Error"] = stripXmlTags(line: line)
    default:
      break
    }
  }
  /*
   "<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n<QRZDatabase version=\"1.36\" xmlns=\"http://xmldata.qrz.com\">\n<Callsign>\n<call>W6OP</call>\n<fname>Peter H</fname>\n<name>Bourget</name>\n<addr2>Stockton</addr2>\n<state>CA</state>\n<country>United States</country>\n</Callsign>\n<Session>\n<Key>1d8a0db2f2a1092bf58c938f14c57767</Key>\n<Count>212</Count>\n<SubExp>non-subscriber</SubExp>\n<Message>A subscription is required to access the complete record.</Message>\n<GMTime>Thu Feb 23 16:12:47 2023</GMTime>\n<Remark>cpu: 0.023s</Remark>\n</Session>\n</QRZDatabase>\n"
   */

  /// Check if the received data is XML and further process it.
  /// - Parameters:
  ///   - html: String
  ///   - spotInformation: SpotInformation: ([String : String], (spotId: Int, sequence: Int))
  func parseCallSignData(html: String)
                          -> ([String : String]) {

    var callSignDictionary =  [String: String]()

    if html.contains(MessageContent.xmlHeader) {
      let lines = html.split(whereSeparator: \.isNewline)
      for line in lines where !line.isEmpty {
        let trimmedline = line.trimmingCharacters(in: .whitespaces)
        populateCallSignDictionary(line: String(trimmedline), callSignDictionary: &callSignDictionary)
      }
    }

    return callSignDictionary
  }


  /// Populate the call sign dictionary with the values from the returned xml.
  /// - Parameters:
  ///   - line: String
  ///   - callSignDictionary: [String : String]
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
    case _ where line.contains(MessageContent.message):
      callSignDictionary["Message"] = stripXmlTags(line: line)
      // <Message>A subscription is required to access the complete record.</Message>
    default:
      break
    }
  }

  /// Strip the < and > off the value of the line.
  /// - Parameter line: String
  /// - Returns: String
  func stripXmlTags(line: String) -> String {
    let start = line.firstIndex(of: ">")
    let startIndex = line.index(after: start!)
    let end = line.lastIndex(of: "<")
    let endIndex = line.index(before: end!)
    let range = startIndex...endIndex
    return String(line[range])
  }


} // end class

/* if has account but not xml subscription
 "<?xml version=\"1.0\" encoding=\"utf-8\" ?>\n<QRZDatabase version=\"1.36\" xmlns=\"http://xmldata.qrz.com\">\n
 <Callsign>\n<call>W6OP</call>\n
 <fname>Peter H</fname>\n
 <name>Bourget</name>\n
 <addr2>Stockton</addr2>\n
 <state>CA</state>\n
 <country>United States</country>\n
 </Callsign>\n<Session>\n
 <Key>a8f95100f18bfbe9bf69c8e5cdd3d8c4</Key>\n
 <Count>9125</Count>\n
 <SubExp>non-subscriber</SubExp>\n
 <Message>A subscription is required to access the complete record.</Message>\n
 <GMTime>Thu Apr 20 19:33:03 2023</GMTime>\n
 <Remark>cpu: 0.021s</Remark>\n</Session>\n
 </QRZDatabase>\n"
 */

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
