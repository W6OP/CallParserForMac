import Testing
@testable import CallParser

struct CallStructureTests {
    @Test func twoComponentCalls() {
        let cases: [(String, CallStructureType, String, String)] = [
            ("W6OP/4", .callDigit, "W6OP", "4"),
            ("W6OP/P", .callPortable, "W6OP", "P"),
            ("W6OP/JOHN", .callText, "W6OP", "JOHN"),
            ("F/W6OP", .prefixCall, "W6OP", "F"),
            ("VE6LB/BY1PK", .callPrefix, "VE6LB", "BY1PK"),
            ("VU4ABC/W6OP", .callPrefix, "VU4ABC", "W6OP"),
            ("VU7ABC/W6OP", .callPrefix, "VU7ABC", "W6OP"),
            ("W6OP/VE6LB", .invalid, "W6OP", "VE6LB")
        ]
        for (call, type, base, prefix) in cases {
            let result = CallStructure(callSign: call, portablePrefixShapePatterns: [])
            #expect(result.callStructureType == type)
            #expect(result.baseCall == base)
            #expect(result.prefix == prefix)
        }
    }
    @Test func threeComponentCalls() {
        let cases: [(String, CallStructureType, String, String)] = [
            ("W6OP/4/P", .callDigitPortable, "W6OP", "4"),
            ("W6OP/4/JOHN", .callDigitText, "W6OP", "4"),
            ("W6OP/P/MM", .callPortablePortable, "W6OP", "P"),
            ("W6OP/P/W3", .callPortablePrefix, "W6OP", "W3"),
            ("W6OP/P/JOHN", .callPortableText, "W6OP", "P"),
            ("W6OP/W3/P", .callPrefixPortable, "W6OP", "W3"),
            ("F/W6OP/P", .prefixCallPortable, "W6OP", "F"),
            ("F/W6OP/JOHN", .prefixCallText, "W6OP", "F"),
            ("W6OP/P/4", .callDigitPortable, "W6OP", "4"),
            ("W6OP/4/5", .invalid, "W6OP", "4")
        ]
        for (call, type, base, prefix) in cases {
            let result = CallStructure(callSign: call, portablePrefixShapePatterns: ["@#/"])
            #expect(result.callStructureType == type, "\(call)")
            #expect(result.baseCall == base, "\(call)")
            #expect(result.prefix == prefix, "\(call)")
        }
    }
}
