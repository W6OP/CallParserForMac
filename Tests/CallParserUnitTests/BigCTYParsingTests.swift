import Testing
@testable import CallParser

struct BigCTYParsingTests {
    @Test func parsesEntitiesAliasesAndZoneOverrides() throws {
        let lookup = CallLookup(parsedData: PrefixFileParser.parse())
        let csv = """
        K,United States,291,NA,5,8,40,98,5,K1(4)[7] =K1ABC(3)[6] W1;
        W1,Second Entity,999,NA,1,2,10,-20,3,K1;
        malformed
        """
        let data = try lookup.parseBigCTYCSV(csv)
        let entity = try #require(data.entities["K"])
        #expect(entity.country == "United States")
        #expect(entity.longitude == -98)

        let alias = try #require(data.entities["K1"])
        #expect(alias.country == "United States")
        #expect(alias.cqZone == 4)
        #expect(alias.ituZone == 7)
        #expect(data.entities["W1"]?.country == "Second Entity")

        let exact = try #require(data.exactMatches["K1ABC"])
        #expect(exact.entity.prefix == "K")
        #expect(exact.cqZoneOverride == 3)
        #expect(exact.ituZoneOverride == 6)
    }
}
