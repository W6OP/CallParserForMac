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
}
