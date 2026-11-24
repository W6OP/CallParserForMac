import Testing
@testable import CallParser

struct MaskBitsetTests {
    @Test(arguments: [
        ("[A-C]#", "B5", true),
        ("[A-C]#", "D5", false),
        ("[#A-C]@", "2X", true),
        ("[#A-C]@", "DX", false),
        ("[C-A]/", "B/", true),
        ("[0-C]", "B", true),
        ("[0-C]", "C", false),
        ("[W-3]", "X", true),
        ("[W-3]", "Z", false),
        ("[]", "A", false),
        ("[A-]", "A", true),
        ("?@#.", "1A2.", true)
    ])
    func compilesAndMatchesMasks(mask: String, call: String, expected: Bool) throws {
        let compiled = try #require(MaskBitset.compile(mask))
        let bits = try #require(call.toCallBits())
        #expect(compiled.matches(bits) == expected)
    }

    @Test(arguments: ["", "  ", "[ABC", "A["])
    func rejectsUnterminatedOrEmptyMasks(mask: String) {
        #expect(MaskBitset.compile(mask) == nil)
    }
}
