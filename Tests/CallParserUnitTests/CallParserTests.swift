//
//  CallParser_DemoTests.swift
//  CallParser DemoTests
//
//  Created by Peter Bourget on 7/29/21.
//  Copyright © 2021 Peter Bourget. All rights reserved.
//

import XCTest
import CallParser

class CallParser_DemoTests: XCTestCase {

  let callParser: PrefixFileParser = PrefixFileParser()
  lazy var callLookup: CallLookup = {
    return CallLookup(prefixFileParser: callParser)
  }()

  override func setUpWithError() throws {
    // Put setup code here. This method is called before the invocation of each test method in the class.

  }

  override func tearDownWithError() throws {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
  }

  func testCallLookup() throws {
    // Use XCTAssert and related functions to verify your tests produce the correct results.

    var result = [Hit]()
    var expected: Int

    // Add calls where mask ends with '.' ie: KG4AA and as compare KG4AAA
    let testCallSigns = ["TX9", "TX4YKP/R", "/KH0PR", "W6OP/4", "OEM3SGU/3", "AM70URE/8", "5N31/OK3CLA", "BV100", "BY1PK/VE6LB", "VE6LB/BY1PK", "DC3RJ/P/W3", "RAEM", "AJ3M/BY1RX", "4D71/N0NM", "OEM3SGU"]

    let testResult = [0, 7, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 1, 1, 1]

    for (index, callSign) in testCallSigns.enumerated() {
      result = callLookup.lookupCall(call: callSign)
      expected = testResult[index]
      print("Call: \(callSign) Expected: \(expected) :: Result: \(result.count)")
      XCTAssert(expected == result.count, "Expected: \(expected) :: Result: \(result.count)")
    }

  }

  func testCallLookupEx() throws {
    // Use XCTAssert and related functions to verify your tests produce the correct results.

    var result = [Hit]()
    var expected: (Int, String)
    var isMatchFound = false

    for (_, callSign) in goodDataCheck.keys.enumerated() {

      result = callLookup.lookupCall(call: callSign)

      switch result.count {
      case 0:
        // check badData
        break
      case 1:
        expected = goodDataCheck[callSign]!
        if result[0].kind == .province {
          XCTAssert(expected == (result[0].dxcc_entity, result[0].province), "Expected: \(expected) :: Result: \(result.count)")
        }
        else {
          XCTAssert(expected == (result[0].dxcc_entity, result[0].country), "Expected: \(expected) :: Result: \(result.count)")
        }
      default:
        for hit in result {
          expected = goodDataCheck[callSign]!
          if hit.kind == .province {
            if (hit.dxcc_entity, hit.province) == expected {
              isMatchFound = true;
            }
          }
          else {
            if (hit.dxcc_entity, hit.country) == expected {
              isMatchFound = true;
            }
          }
        }
        XCTAssert(isMatchFound == true)
      }
    }
  }

  var goodDataCheck = ["AM70URE/8": (029, "Canary Is."),
                       "PU2Z": (108, "Call Area 2"),
                       "IG0NFQ": (248, "Lazio;Umbria"),
                       "IG0NFU": (225, "Sardinia"),
                       "W6OP": (291, "CA"),
                       "TJ/W6OP": (406, "Cameroon"),
                       "W6OP/3B7": (004, "St. Brandon"),
                       "KL6OP": (006, "Alaska") ,
                       "YA6AA": (003, "Afghanistan"),
                       "3Y2/W6OP": (024, "Bouvet I."),
                       "W6OP/VA6": (001, "Alberta") ,
                       "VA6AY": (001, "Alberta") ,
                       "CE7AA": (112, "Aisen;Los Lagos (Llanquihue, Isla Chiloe and Palena)") ,
                       "3G0DA": (112, "Chile") ,
                       "FK6DA": (512, "Chesterfield Is.") ,
                       "BA6V": (318, "Hu Bei") ,
                       "5J7AA": (116, "Arauca;Boyaca;Casanare;Santander") ,
                       "TX4YKP/R": (298, "Wallis & Futuna Is.") ,
                       "TX4YKP/B": (162, "New Caledonia") ,
                       "TX4YKP": (509, "Marquesas I.") ,
                       "TX5YKP": (175, "French Polynesia") ,
                       "TX6YKP": (036, "Clipperton I.") ,
                       "TX7YKP": (512, "Chesterfield Is.") ,
                       "TX8YKP": (508, "Austral I.") ,
                       "KG4AA": (105, "Guantanamo Bay") ,
                       "KG4AAA": (291, "AL;FL;GA;KY;NC;SC;TN;VA"),
                       "BS4BAY/P": (506, "Scarborough Reef"),
                       "CT8AA": (149, "Azores"),
                       "BU7JP": (386, "Taiwan"),
                       "BU7JP/P": (386, "Kaohsiung"),
                       "VE0AAA": (001, "Canada"),
                       "VE3NEA": (001, "Ontario"),
                       "VK9O": (150, "External territories"),
                       "VK9OZ": (150, "External territories"),
                       "VK9OC": (038, "Cocos-Keeling Is."),
                       "VK0M/MB5KET": (153, "Macquarie I."),
                       "VK0H/MB5KET": (111, "Heard I."),
                       "WK0B": (291, "CO;IA;KS;MN;MO;ND;NE;SD"),
                       "VP2V/MB5KET": (065, "British Virgin Is."),
                       "VP2M/MB5KET": (096, "Montserrat"),
                       "VK9X/W6OP": (035, "Christmas Is."),
                       "VK9/W6OP": (035, "Christmas Is."),
                       "VK9/W6OA": (303, "Willis I."),
                       "VK9/W6OB": (150, "External territories"),
                       "VK9/W6OC": (038, "Cocos-Keeling Is."),
                       "VK9/W6OD": (147, "Lord Howe I."),
                       "VK9/W6OE": (171, "Mellish Reef"),
                       "VK9/W6OF": (189, "Norfolk I."),
                       "RA9BW": (015, "Chelyabinskaya oblast"),
                       "RA9BW/3": (054, "Central"),
                       "LR9B/22QIR": (100, "Argentina"),
                       "6KDJ/UW5XMY": (137, "South Korea"),
                       "WP5QOV/P": (43, "Desecheo I."),
                       // bad calls
                       "NJY8/QV3ZBY": (291, "United States"),
                       "QZ5U/IG0NFQ": (248, "Lazio;Umbria"),
                       "Z42OIO": (0, "Unassigned prefix")
  ]

  // { "LR9B/22QIR", (0, "invalid prefix pattern and invalid call")
  var badDataCheck = [ "QZ5U/IG0NFQ": "valid prefix pattern but invalid prefix",
                       "NJY8/QV3ZBY": "invalid prefix pattern and invalid call",
                       "Z42OIO": "Unassigned prefix"
  ]
}
