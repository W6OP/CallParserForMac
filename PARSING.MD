//
//  PARSING.MD
//  CallParser
//
//  Created by Peter Bourget on 5/18/26.
//

PrefixList.xml structure

Each <prefix> element is one record describing a callsign space (DXCC entity, province, invalid prefix, etc.). Inside:

• <masks> — zero or more <mask> patterns describing call shapes that match this record. Masks use a small DSL:
   • # = any digit (0–9)
   • @ = any letter (A–Z)
   • ? = any alphanumeric
   • [ABC] = character set (one of A, B, C)
   • [A-G], [0-5], [A-3] = ranges (alpha→alpha, num→num, mixed)
   • / = portable indicator (suffix only)
   • . = "stop" / end-of-call indicator (so [.A-Z] means "no char OR one of those letters")
   • Example: B[#A-LRTYZ][1-689][#YZ] mixes literals, digit-meta, ranges, and a letter set.
• <label> — display prefix (e.g. KL, 3B6.3B6).
• <kind> — pfDXCC, pfProvince, pfInvalidPrefix, etc. (maps to PrefixKind).
• <dxcc_entity>, <wae_entity> — numeric ADIF keys.
• <cq_zone>, <itu_zone> — may be lists (parsed via buildZoneList).
• <continent>, <country>, <province>, <province_id> (→ admin1), <time_zone>, <lat>, <long>, <city>, <wap_entity>, <start_date>, <end_date> — straightforward fields.

How XmlParser.swift consumes it

XmlParser.swift􀰓 is an extension that makes PrefixFileParser conform to XMLParserDelegate. The flow:

1. didStartElement (XmlParser.swift:29) — when a <prefix> opens, allocates a fresh PrefixData and tempMaskList. Otherwise just resets currentValue.
2. foundCharacters (XmlParser.swift:45) — appends text. Foundation can split a text node (e.g. around &amp;), so it accumulates rather than overwrites.
3. didEndElement (XmlParser.swift:54) — switches on the element name and stores the trimmed value into the matching PrefixData field. Masks are collected into prefixData.tempMaskList.
4. End of <prefix> record (XmlParser.swift:108–145) — the record gets indexed:
   • kind == .dXCC → stored in adifs[dxcc_entity]
   • kind == .invalidPrefix → stored at adifs[0]
   • wae != 0 → also stored at adifs[wae]
   • Province records get added to admins
   • Mask expansion: each raw mask is fed to expandMask → buildMaskPattern (PrefixFileParser.swift:89, 133). This converts a mask into one or more "shape patterns" using CharacterType codes (alpha @, numeric #, alphanumeric ?, plus / and .). refinePattern (line 197) handles ? by emitting both an alpha and a numeric variant.
   • savePatternList (line 221) buckets the resulting patterns: anything ending in / goes into portablePrefixPatterns, everything else into callSignPatterns (skipping invalid-prefix records).

End result

After parsing, three dictionaries are exposed and snapshotted into a ParsedPrefixData value (PrefixFileParser.swift:46):

• callSignPatterns: [String: [PrefixData]] — keyed by shape pattern like @@#@, @#@@, etc.
• portablePrefixPatterns: [String: [PrefixData]] — same idea, keys end in /.
• adifs: [Int: PrefixData] — keyed by DXCC/WAE entity number.

At lookup time, a callsign gets converted into one of those shape pattern strings, the dictionary is hit directly (O(1)), and the candidate PrefixData records are then filtered against the actual mask characters to pick the winner.

So the XML is essentially a mask catalog, and the parser's job is to (a) hydrate PrefixData records and (b) pre-compute the pattern → records index that makes lookup fast.


VE3NEA Approach

Yes — what you probably saw is a per-position bitset (bitmask) matcher, which is what VE3NEA's original Delphi/C# code uses. It's both faster and more accurate than the shape-pattern approach.

The idea in one paragraph

Every position in a callsign holds one of ~36 symbols (A–Z, 0–9). You can represent "the set of characters allowed at position i of mask m" as a single UInt64 with one bit per symbol. A mask of length N becomes an array of N UInt64s. Matching a callsign character is then: shift 1 << charIndex and AND with the mask bitset — one CPU instruction per position. No string parsing, no Set.contains, no range expansion at lookup time.

Why it beats the current approach

The current code does two stages: (1) build a "shape" key like @@#@ and look up candidates, then (2) walk the original mask strings character-by-character to disambiguate among many shape-colliding candidates. Step 2 is the slow part and is also where accuracy suffers (the shape key is lossy — KH7K and W6OP both shape to @#@@ but have entirely different mask sets).

With bitsets:
• [ABD-KOPQS-VYZ] is computed once at load time into one UInt64. Range expansion happens in the parser, never at lookup.
• Each mask stores [UInt64] (one per char position). Matching a callsign is N ANDs — no branching on character class, no shape lookup.
• You typically index masks by (length, first char) or (length, first two chars) to prune candidates, then bitset-test the remaining few. The lossy @@#@ intermediate goes away.

Other wins

• Portable indicator / and the . "stop" sentinel are just two extra bits in the same word — no special-case code paths.
• Scoring "best match" (longest literal prefix, fewest wildcards) is trivial: count bits per position and prefer masks where the matched bit was in a smaller set (more specific).
• Memory shrinks: 21k masks × ~6 positions × 8 bytes ≈ 1 MB, versus today's dictionary of arrays of PrefixData references.

Tradeoffs

• It's a meaningful rewrite of expandMask / buildMaskPattern / savePatternList plus the lookup side in CallLookup. The XML and PrefixData stay the same.
• Less Swift-idiomatic — you're working with UInt64 and bit twiddling, which reads more like C. Worth a few extension UInt64 helpers (contains(_ char: Character), etc.) to keep call sites readable.
• For a one-time init-cost cache like yours, the current approach is "fast enough" until you batch — that's why you didn't feel it before adding lookupBatch. If per-call latency is the metric you care about (e.g. real-time spotting), the bitset approach typically gives 5–20× on the hot path.

Done. Summary of what changed and what was preserved:

New file
• Sources/CallParser/MaskBitset.swift􀰓 — CallSymbol (bit encoding), MaskBitset (compiled mask + compile(_:) + matches(_:)), BitsetMaskIndex (length+firstChar bucketed index), String.toCallBits().

Modified (all additive — nothing removed or changed in existing behaviour)
• PrefixFileParser.swift􀰓 — added var bitsetIndex = BitsetMaskIndex() property; parse() now passes it into ParsedPrefixData.
• XmlParser.swift􀰓 — inside the per-mask loop in didEndElement, compile each raw mask and insert it into bitsetIndex (skipping invalid-prefix records, matching the legacy filter).
• CallParserCommon.swift􀰓 — ParsedPrefixData gains a bitsetIndex field with a default value, so the deprecated convenience initializers keep working unchanged.
• CallLookup.swift􀰓 — stores bitsetIndex from the parsed data and exposes two public benchmark primitives:
   • bitsetCandidates(for callSign: String) -> [PrefixData]
   • bitsetIndexEntryCount: Int (sanity-check the index populated)

Benchmark code

let parsed = PrefixFileParser.parse()
let lookup = CallLookup(parsedData: parsed)
print("bitset entries:", lookup.bitsetIndexEntryCount)

let calls = CallLookup.loadCallSigns(from: .pskreporter)

let t0 = ContinuousClock().now
var legacy = 0
for c in calls { legacy += lookup.parseCallSign(c).count }
let dLegacy = ContinuousClock().now - t0

let t1 = ContinuousClock().now
var bitset = 0
for c in calls { bitset += lookup.bitsetCandidates(for: c).count }
let dBitset = ContinuousClock().now - t1

print("legacy:", dLegacy, "bitset:", dBitset, "ratio:", Double(dLegacy.components.attoseconds) / Double(dBitset.components.attoseconds))


The legacy lookup returns full Hit results after disambiguation, while bitsetCandidates just returns the candidate set, so the comparison overstates the bitset's advantage. To compare apples-to-apples you'd time only the candidate-finding step inside searchMainDictionary against bitsetCandidates. The numbers should still tell you whether wiring this in is worth the next round of work — replacing the determinePatternToUse + matchPattern pair with bitsetCandidates inside searchMainDictionary, keeping the downstream refineList disambiguation.

Nothing in your existing call path was altered, so legacy behaviour is byte-identical to before.
