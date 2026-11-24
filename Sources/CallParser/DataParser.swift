//
//  File.swift
//  
//
//  Created by Peter Bourget on 11/17/22.
//

import Foundation
import os

struct DataParser {

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
    static let geoloc = "<geoloc>"
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

  /// Take the session xml and populate the sessionDictionary.
  /// - Parameter html: String
  /// - Returns: [String : String]
  func parseSessionData(html: String) -> [String : String] {
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
    case _ where line.contains(MessageContent.geoloc):
      callSignDictionary["geoloc"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.lotw):
      callSignDictionary["lotw"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.aliases):
      callSignDictionary["aliases"] = stripXmlTags(line: line)
    case _ where line.contains(MessageContent.key):
      callSignDictionary["Key"] = stripXmlTags(line: line)
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
    guard let start = line.firstIndex(of: ">"),
          let end = line.lastIndex(of: "<"),
          start < end else {
      return ""
    }
    return String(line[line.index(after: start)..<end]).trimmed
  }

} 


