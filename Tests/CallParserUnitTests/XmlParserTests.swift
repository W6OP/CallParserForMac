import Foundation
import Testing
@testable import CallParser

struct XmlParserTests {
    @Test func parsesFieldsAndIndexesMasks() throws {
        let delegate = PrefixFileParser()
        delegate.adifs = [:]
        delegate.bitsetIndex = BitsetMaskIndex()
        delegate.portablePrefixShapePatterns = []
        let xml = """
        <prefixes>
          <prefix>
            <label>AA.BB</label><kind>pfDXCC</kind><country>Alpha &amp; Beta</country>
            <province>Region</province><dxcc_entity>123</dxcc_entity>
            <cq_zone>3,4</cq_zone><itu_zone>6,7</itu_zone><continent>NA</continent>
            <time_zone>5</time_zone><lat>42.1</lat><long>-71.2</long><city>Example</city>
            <wap_entity>WAP1</wap_entity><wae_entity>456</wae_entity><province_id>RG</province_id>
            <start_date>2020</start_date><end_date>2030</end_date>
            <mask>AB#</mask><mask>AB#/</mask><mask>[broken</mask>
          </prefix>
          <prefix><kind>pfInvalidPrefix</kind><mask>ZZ#</mask></prefix>
        </prefixes>
        """
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        #expect(parser.parse())
        let record = try #require(delegate.adifs[123])
        #expect(record.fullPrefix == "AA.BB")
        #expect(record.mainPrefix == "BB")
        #expect(record.country == "Alpha & Beta")
        #expect(record.province == "Region")
        #expect(record.cqZone == [3, 4] && record.ituZone == [6, 7])
        #expect(record.continent == "NA" && record.timeZone == "5")
        #expect(record.latitude == "42.1" && record.longitude == "-71.2")
        #expect(record.city == "Example" && record.wap == "WAP1" && record.wae == 456)
        #expect(record.admin1 == "RG" && record.startDate == "2020" && record.endDate == "2030")
        #expect(delegate.adifs[456]?.dxccEntity == 123)
        #expect(delegate.adifs[0]?.kind == .invalidPrefix)
        #expect(delegate.portablePrefixShapePatterns.contains("@@#/"))
        let callBits = try #require("AB1".toCallBits())
        #expect(delegate.bitsetIndex.candidates(for: callBits).count == 1)
        let invalidBits = try #require("ZZ1".toCallBits())
        #expect(delegate.bitsetIndex.candidates(for: invalidBits).isEmpty)
    }
}
