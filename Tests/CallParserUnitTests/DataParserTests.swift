import Testing
@testable import CallParser

struct DataParserTests {
    @Test(arguments: [
        ("<call>  W6OP  </call>", "W6OP"),
        ("<call></call>", ""),
        ("<call>   </call>", ""),
        ("", ""),
        ("no tags", ""),
        ("<call>value", ""),
        ("value</call>", ""),
        ("><", "")
    ])
    func stripXmlTagsHandlesEmptyAndMalformedInput(input: String, expected: String) {
        #expect(DataParser().stripXmlTags(line: input) == expected)
    }
    @Test func populatesAllSupportedCallSignFields() {
        let parser = DataParser()
        let keys = ["call", "country", "dxcc", "addr2", "county", "state", "lat", "lon", "grid",
                    "geoloc", "lotw", "aliases", "Key", "Error", "Message"]
        var result = [String: String]()
        for key in keys {
            parser.populateCallSignDictionary(line: "<\(key)>value-\(key)</\(key)>", callSignDictionary: &result)
        }
        parser.populateCallSignDictionary(line: "<unknown>ignored</unknown>", callSignDictionary: &result)
        #expect(result.count == keys.count)
        for key in keys {
            #expect(result[key] == "value-\(key)")
        }
        parser.populateCallSignDictionary(line: "<Message>first</Message><call>second</call>", callSignDictionary: &result)
        #expect(result["call"] == "first</Message><call>second")
        #expect(result["Message"] == "value-Message")
    }
}
