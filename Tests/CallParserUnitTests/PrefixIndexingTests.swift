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

    @Test(arguments: [2, 3, 4, 5, 6, 7])
    func matchesEachSupportedMaskLength(length: Int) {
        let letters = Array("ABCDEFG".prefix(length)).map(String.init)
        var data = PrefixData()
        data.maskList = [letters.map { [$0] }]
        data.sortMaskList()
        var rank = 99
        #expect(data.setSearchRank(prefix: letters.joined(), excludePortablePrefixes: false, searchRank: &rank))
        #expect(rank == length)
        let mismatched = letters.dropLast().joined() + "Z"
        #expect(!data.setSearchRank(prefix: mismatched, excludePortablePrefixes: false, searchRank: &rank))
        #expect(rank == 1)
    }

    @Test func excludesPortableMasksAndRejectsUnsupportedLengths() {
        var data = PrefixData()
        data.maskList = [[["A"], ["B"], ["/"]]]
        data.sortMaskList()
        var rank = 0
        #expect(data.setSearchRank(prefix: "AB/", excludePortablePrefixes: false, searchRank: &rank))
        #expect(rank == 3)
        #expect(!data.setSearchRank(prefix: "AB/", excludePortablePrefixes: true, searchRank: &rank))
        #expect(rank == 1)

        data.maskList = [Array("ABCDEFGH").map { [String($0)] }]
        data.sortMaskList()
        #expect(!data.setSearchRank(prefix: "ABCDEFGH", excludePortablePrefixes: false, searchRank: &rank))
        #expect(rank == 1)
        #expect(data.setSearchRank(prefix: "AB", excludePortablePrefixes: false, searchRank: &rank))
        #expect(rank == 2)
    }

    @Test(arguments: [("", "4", "4/"), ("W6", "4", "W4/"), ("JA3", "6", "JA6/")])
    func callAreaReplacementHandlesPrefixLengths(mainPrefix: String, area: String, expected: String) {
        let lookup = CallLookup(parsedData: PrefixFileParser.parse())
        #expect(lookup.replaceCallArea(mainPrefix: mainPrefix, prefix: area) == expected)
    }
}
