import Testing
@testable import CallParser

struct CallSignCleaningTests {
    @Test(arguments: [
        ("", ""),
        ("  \t\n", ""),
        ("  w6op  ", "W6OP"),
        ("//w6op///p//", "W6OP/P"),
        ("/\u{0001}/w6op\u{007F}/p/", "W6OP/P"),
        ("w6 op", ""),
        ("w6%op", ""),
        ("  w6\top  ", "W6OP"),
        ("é1a/ç", "é1A/ç"),
        ("///", "")
    ])
    func normalizesCallSigns(input: String, expected: String) {
        let lookup = CallLookup()
        #expect(lookup.cleanCallSign(callSign: input) == expected)
    }
}
