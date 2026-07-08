//
//  CallParser_DemoTests.swift
//  CallParser DemoTests
//
//  Created by Peter Bourget on 7/29/21.
//  Copyright © 2021 Peter Bourget. All rights reserved.
//

import Testing
@testable import CallParser

@Suite("CallParser tests")
struct CallParser_DemoTests {

  let callLookup: CallLookup

  init() {
    callLookup = CallLookup(parsedData: PrefixFileParser.parse())
  }

  @Test func callLookup_returnsExpectedHitCounts() async throws {
    // Add calls where mask ends with '.' ie: KG4AA and as compare KG4AAA.
    // Note: `OEM3SGU` and `OEM3SGU/3` are long-standing typos for `OE3SGU`
    // (Austria) and resolve to no hits under strict bitset matching, since
    // `OEM` is not a registered Austrian prefix shape.
    let testCallSigns = ["TX9", "TX4YKP/R", "/KH0PR", "W6OP/4", "OEM3SGU/3", "AM70URE/8", "5N31/OK3CLA", "BV100", "BY1PK/VE6LB", "VE6LB/BY1PK", "DC3RJ/P/W3", "RAEM", "AJ3M/BY1RX", "4D71/N0NM", "OEM3SGU"]

    let testResult = [0, 7, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0]

    for (index, callSign) in testCallSigns.enumerated() {
      let result = await callLookup.lookupCall(callSign: callSign)
      let expected = testResult[index]
      print("Call: \(callSign) Expected: \(expected) :: Result: \(result.count)")
      #expect(expected == result.count, "Expected: \(expected) :: Result: \(result.count)")
    }
  }

  @Test func callLookup_matchesGoodDataCheck() async throws {
    // Iterate every entry in `goodDataCheck` and assert independently per
    // iteration so failures are deterministic and surface the offending
    // call sign. Entries that legitimately produce no hits are listed in
    // `badDataCheck` and are not exercised here.
    for callSign in goodDataCheck.keys.sorted() {
      let expected = goodDataCheck[callSign]!
      let result = await callLookup.lookupCall(callSign: callSign)
      print("testing good calls \(callSign)")

      switch result.count {
      case 0:
        Issue.record("\(callSign): no hits returned; expected \(expected)")
      case 1:
        let hit = result[0]
        let actual: (Int, String) = hit.kind == .province
          ? (hit.dxcc_entity, hit.province)
          : (hit.dxcc_entity, hit.country)
        #expect(
          actual.0 == expected.0,
          "\(callSign) DXCC entity: expected \(expected), got \(actual)"
        )
        #expect(
          actual.1 == expected.1,
          "\(callSign) label: expected \(expected), got \(actual)"
        )
      default:
        let isMatchFound = result.contains { hit in
          let candidate: (Int, String) = hit.kind == .province
            ? (hit.dxcc_entity, hit.province)
            : (hit.dxcc_entity, hit.country)
          return candidate == expected
        }
        #expect(
          isMatchFound,
          "\(callSign): no hit matched expected \(expected) among \(result.count) hits"
        )
      }
    }
  }

  let goodDataCheck = ["AM70URE/8": (029, "Canary Is."),
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
                       "WP5QOV/P": (43, "Desecheo I."),
                       "F/HB9NBG/P": (227, "France")
                       // NJY8/QV3ZBY, QZ5U/IG0NFQ, Z42OIO -- see badDataCheck
  ]

  // MARK: - Parallel lookup tests

  @Test func lookupCallPairGrouped_returnsSpotterAndDxHits() async throws {
    let result = await callLookup.lookupCallPairGrouped(spotter: "W6OP", dx: "VA6AY")

    #expect(!result.spotter.isEmpty, "Spotter should have hits")
    #expect(!result.dx.isEmpty, "DX should have hits")
    #expect(result.spotter.first?.call == "W6OP")
    #expect(result.dx.first?.call == "VA6AY")
  }

  @Test func lookupBatch_returnsResultForEveryCallSign() async throws {
    let callSigns = ["W6OP", "VA6AY", "KG4AA", "CT8AA"]
    let results = await callLookup.lookupBatch(callSigns: callSigns)

    #expect(results.count == callSigns.count, "Should have results for all call signs")
    for call in callSigns {
      let hits = results[call]
      #expect(hits != nil, "Missing result for \(call)")
      #expect(hits?.isEmpty == false, "Result for \(call) should not be empty")
    }
  }

  @Test func qrzResponseErrorDescription_preservesServerMessage() {
    let message = "Password incorrect\nA subscription is required to obtain the complete data."
    let error = QRZManagerError.qrzResponse(message)

    #expect(error.errorDescription == message)
  }

  @Test func parseCallSignData_preservesSessionKey() {
    let html = """
    <?xml version=\"1.0\" encoding=\"utf-8\" ?>
    <QRZDatabase version=\"1.34\" xmlns=\"http://xmldata.qrz.com\">
      <Callsign>
        <call>W6OP</call>
      </Callsign>
      <Session>
        <Key>abc123</Key>
      </Session>
    </QRZDatabase>
    """

    let dictionary = DataParser().parseCallSignData(html: html)

    #expect(dictionary["Key"] == "abc123")
  }

  let badDataCheck = [ "QZ5U/IG0NFQ": "valid prefix pattern but invalid prefix",
                       "NJY8/QV3ZBY": "invalid prefix pattern and invalid call",
                       "Z42OIO": "Unassigned prefix",
                       "LR9B/22QIR": "invalid prefix pattern and invalid call",
                       "6KDJ/UW5XMY": "invalid prefix pattern and invalid call"
  ]
}
