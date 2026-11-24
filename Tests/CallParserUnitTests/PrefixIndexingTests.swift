import Testing
@testable import CallParser

struct PrefixIndexingTests {
    @Test func safelyMatchesShortAndLongPrefixes() {
        var data = PrefixData()
        data.maskList = [[], [["A"], ["B"], ["C"], ["D"], ["E"], ["F"]],
                         [["A"], ["B"], ["C"], ["D"], ["E"], ["F"], ["G"]]]
        data.sortMaskList()
        var rank = 0
        #expect(!data.setSearchRank(prefix: "", excludePortablePrefixes: false, searchRank: &rank))
        #expect(!data.setSearchRank(prefix: "A", excludePortablePrefixes: false, searchRank: &rank))
        #expect(data.setSearchRank(prefix: "ABCDEF", excludePortablePrefixes: false, searchRank: &rank))
        #expect(rank == 6)
        #expect(data.setSearchRank(prefix: "ABCDEFG", excludePortablePrefixes: false, searchRank: &rank))
        #expect(rank == 7)
        #expect(data.setSearchRank(prefix: "ABCDEFX", excludePortablePrefixes: false, searchRank: &rank))
        #expect(rank == 6)
        #expect(!data.setSearchRank(prefix: "ABCDEXG", excludePortablePrefixes: false, searchRank: &rank))
    }

    @Test(arguments: [("", "4", "4/"), ("W6", "4", "W4/"), ("JA3", "6", "JA6/")])
    func callAreaReplacementHandlesPrefixLengths(mainPrefix: String, area: String, expected: String) {
        let lookup = CallLookup(parsedData: PrefixFileParser.parse())
        #expect(lookup.replaceCallArea(mainPrefix: mainPrefix, prefix: area) == expected)
    }
}
