import Foundation
import os

// MARK: - Process Callsign

extension CallLookup {

  /// Parses a call sign into its component parts using the prefix dictionary.
  /// - Parameter call: The cleaned call sign.
  /// - Returns: Array of `Hit` results. Caching is the caller's responsibility.
  func processCallSign(call: String) -> [Hit] {
    let callStructure = CallStructure(
      callSign: call,
      portablePrefixShapePatterns: portablePrefixShapePatterns
    )
    guard callStructure.callStructureType != .invalid else { return [] }
    return collectMatches(callStructure: callStructure)
  }

  /// Local resolution chain used by ``lookupCall(callSign:)`` once QRZ is out
  /// of the picture. Order (QRZ itself is handled by the caller, above this):
  ///
  /// 1. BigCTY **exact** call-sign match — authoritative for a specific call
  ///    (e.g. `OR4TN` -> Antarctica), so it beats the parser.
  /// 2. CallParser prefix resolution.
  /// 3. BigCTY **country/prefix** match — the coarse last resort.
  ///
  /// - Parameter call: The cleaned, suffix-stripped call sign.
  /// - Returns: A single-element array from whichever step resolves, or `[]`.
  func resolveLocally(call: String) -> [Hit] {
    if let exact = resolveFromBigCTYExact(call: call) { return [exact] }

    let hits = processCallSign(call: call)
    if !hits.isEmpty { return hits }

    if let prefix = resolveFromBigCTYPrefix(call: call) { return [prefix] }
    return []
  }

} // end extension

extension CallLookup {
  // MARK: - Collect matches and search the main dictionary.

  /// Finds matching prefixes for a given call structure, handling portable and digit cases.
  /// - Parameter callStructure: The structured call information.
  /// - Returns: Array of matching `Hit` objects.
  func collectMatches(callStructure: CallStructure) -> [Hit] {
    var matches = [PrefixData]()

    switch callStructure.callStructureType {
    case .callPrefix, .prefixCall, .callPortablePrefix, .callPrefixPortable,
      .prefixCallPortable, .prefixCallText:
      if let hits = checkForPortablePrefix(callStructure: callStructure) {
        return hits
      }
    case .callDigit:
      if let hits = checkReplaceCallArea(callStructure: callStructure) {
        return hits
      }
    default:
      break
    }

    matches = searchMainDictionary(structure: callStructure)
    return buildHit(foundItems: matches, callStructure: callStructure)
  }

  /// Searches the bitset prefix index for matching `PrefixData`.
  ///
  /// Uses the same call-prefix selection logic the legacy `determinePatternToUse`
  /// once did (the candidate string is either the prefix already on the
  /// structure or the baseCall), then matches it against ``BitsetMaskIndex`` —
  /// first with the stop indicator appended, then by progressively shrinking
  /// the candidate by one character.
  ///
  /// Returns at the first non-empty match. The bitset's per-position AND
  /// already does the work that index-key filtering did in the old legacy
  /// code, so no further refinement is required.
  ///
  /// Known limitation — ambiguous CALL/CALL inputs: when an input has the
  /// shape `PREFIX/SUFFIX` and *both* halves look like callsigns (e.g.
  /// `6KDJ/UW5XMY`), ``CallStructure`` picks one as the prefix using
  /// pattern heuristics. The right-shrinking step here will then match
  /// shorter substrings of that prefix against the index (e.g. `6KDJ`
  /// shrinks to `6KD` and matches the Korean `HL` PrefixData), so the
  /// final DXCC reflects the chosen prefix's country, not the other half.
  /// This is unavoidable without country-specific rules. For definitive
  /// resolution of these inputs, use the QRZ.com lookup path instead.
  func searchMainDictionary(structure: CallStructure) -> [PrefixData] {
    var callStructure = structure

    // Mirror `determinePatternToUse` candidate selection.
    let candidate: String
    switch callStructure.callStructureType {
    case .prefixCall, .prefixCallPortable, .prefixCallText:
      candidate = callStructure.prefix ?? callStructure.baseCall
    default:
      callStructure.prefix = callStructure.baseCall
      candidate = callStructure.baseCall
    }

    guard !candidate.isEmpty else { return [] }

    // Encode the candidate's bits into a single buffer once, append the
    // stop indicator at the end, then probe at progressively shorter
    // lengths via ArraySlice. Avoids per-iteration `toCallBits()` /
    // String allocations.
    var bits: [UInt64] = []
    bits.reserveCapacity(candidate.utf8.count + 1)
    for character in candidate {
      guard let bit = CallSymbol.bit(for: character) else { return [] }
      bits.append(UInt64(1) << UInt64(bit))
    }
    let bareLen = bits.count
    bits.append(CallSymbol.stopBit)
    let withStopLen = bits.count

    // Try with the stop indicator first (matches masks that should "end here").
    let withStop = bitsetIndex.candidates(for: bits[..<withStopLen])
    if !withStop.isEmpty { return withStop }

    // Shrink the candidate from the right, like matchPattern shortens the
    // pattern. Stop at length 2 to match the legacy `patternLength > 1`.
    var len = bareLen
    while len >= 2 {
      let matches = bitsetIndex.candidates(for: bits[..<len])
      if !matches.isEmpty { return matches }
      len -= 1
    }

    return []
  }

} // end extension

// MARK: - Portable Prefixes

extension CallLookup {

  /// Checks for portable-prefix formats (e.g., VK4AAA/3) and returns hits.
  func checkForPortablePrefix(callStructure: CallStructure) -> [Hit]? {
    guard let rawPrefix = callStructure.prefix else { return nil }
    let candidates = getPortablePrefixes(prefix: rawPrefix)

    guard !candidates.isEmpty else { return nil }

    return buildHit(foundItems: candidates, callStructure: callStructure)
  }

  /// Bitset-based portable-prefix lookup.
  ///
  /// Ensures the input ends in `/`, then looks it up in ``BitsetMaskIndex``
  /// using three progressively broader strategies:
  ///
  /// 1. Literal portable form (`prefix + "/"`).
  /// 2. Bare prefix without `/` — handles countries that registered the
  ///    broad non-portable mask but not its portable variant (e.g. Canada's
  ///    `V[ABCEGX]6`).
  /// 3. Leading letters + `/` — handles call-area-replacement inputs like
  ///    `UR4/` and `R4/`, which match country-wide portable masks such as
  ///    `U[RT]/` and `R/`.
  func getPortablePrefixes(prefix: String) -> [PrefixData] {
    var portablePrefix = prefix
    if !portablePrefix.hasSuffix("/") { portablePrefix += "/" }
    guard let bits = portablePrefix.toCallBits() else { return [] }
    let portable = bitsetIndex.candidates(for: bits)
    if !portable.isEmpty { return portable }

    let bare = String(portablePrefix.dropLast())
    if let bareBits = bare.toCallBits() {
      let bareMatches = bitsetIndex.candidates(for: bareBits)
      if !bareMatches.isEmpty { return bareMatches }
    }

    let lettersOnly = portablePrefix.prefix { $0.isLetter }
    guard !lettersOnly.isEmpty, lettersOnly.count < bare.count else { return [] }
    let letterPortable = lettersOnly + "/"
    guard let lpBits = String(letterPortable).toCallBits() else { return [] }
    return bitsetIndex.candidates(for: lpBits)
  }

} // end extension

extension CallLookup {
  // MARK: - Build Hits

  /// Builds `Hit` objects from prefix data.
  ///
  /// Caching is the caller's responsibility — typically performed in
  /// ``lookupCall(callSign:)`` once the full result is in hand so that the
  /// cache write is structured under the caller's task.
  ///
  /// - Parameters:
  ///   - foundItems: Matched `PrefixData` array.
  ///   - callStructure: The structured call information.
  /// - Returns: Array of `Hit` objects.
  func buildHit(foundItems: [PrefixData], callStructure: CallStructure) -> [Hit] {
    guard !foundItems.isEmpty else { return [] }

    let call = callStructure.fullCall
    let spotId = callStructure.spotId
    let sequence = callStructure.sequence

    // Skip the sort allocation entirely when there's nothing to sort.
    let listByRank: [PrefixData]
    if foundItems.count == 1 {
      listByRank = foundItems
    } else {
      listByRank = foundItems.sorted { $0.searchRank < $1.searchRank }
    }

    var hitList: [Hit] = []
    hitList.reserveCapacity(listByRank.count)

    // BigCTY is intentionally NOT applied here. Its per-entity coordinate is a
    // country centroid and would clobber the parser's more accurate
    // province-level data. BigCTY is consulted only as a last resort, when the
    // parser yields no hit at all — see ``resolveLocally(call:)``.
    for prefixData in listByRank {
      var hit = Hit(callSign: call, prefixData: prefixData)
      hit.updateHit(spotId: spotId, sequence: sequence)
      hitList.append(hit)
    }
    return hitList
  }

  /// Builds a `Hit` from a QRZ.com call sign dictionary.
  ///
  /// Caching is the caller's responsibility.
  func buildHit(callSignDictionary: [String: String]) -> Hit {
    let originalHit = Hit(callSignDictionary: callSignDictionary)
    return verifiedDXCCInformation(for: originalHit)
  }

  /// Returns a copy of `Hit` with corrected DXCC entity country if mismatched.
  private func verifiedDXCCInformation(for hit: Hit) -> Hit {
    var hit = hit

    guard hit.dxcc_entity != 0 else { return hit }

    if let country = dxccEntities[hit.dxcc_entity]?.trimmed {
      let hitCountry = String(hit.country.trimmed)

      if country.localizedCaseInsensitiveCompare(hitCountry) != .orderedSame {
        hit.country = country

        if verboseLogging {
          let call = hit.call
          logger.log("\(hitCountry) replaced with \(country): \(call)")
        }
      }
    } else {
      hit.country = "invalid dxcc: \(hit.dxcc_entity)"
    }

    return hit
  }

}  // end extension

extension CallLookup {
  // MARK: - Call Area Replacement

  /// Replaces the call area in the prefix if initial lookup fails and retries matching.
  func checkReplaceCallArea(callStructure: CallStructure) -> [Hit]? {
    let digits = callStructure.baseCall.onlyDigits
    var matches = [PrefixData]()

    if callStructure.prefix == (digits.first.map(String.init) ?? "") {
      var updatedStructure = callStructure
      updatedStructure.callStructureType = .call
      return collectMatches(callStructure: updatedStructure)
    }

    matches = searchMainDictionary(structure: callStructure)
    let mainPrefix = matches.first?.mainPrefix ?? ""

    if !mainPrefix.isEmpty {
      var updatedStructure = callStructure
      updatedStructure.prefix = replaceCallArea(
        mainPrefix: mainPrefix,
        prefix: callStructure.prefix
      )

      updatedStructure.callStructureType =
        updatedStructure.prefix.isEmpty ? .call : .prefixCall
      return collectMatches(callStructure: updatedStructure)
    }

    return nil
  }

  /// Computes a new prefix by replacing the call area based on main prefix rules.
  /// - Parameters:
  ///   - mainPrefix: The original main prefix string.
  ///   - prefix: The remainder of the call string.
  /// - Returns: New prefix string including "/" delimiter.
  func replaceCallArea(mainPrefix: String, prefix: String) -> String {
    var position = 0
    let oneCharPrefixes: [String] = ["I", "K", "N", "W", "R", "U"]
    let digitSymbols: [String] = [
      "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "#", "["
    ]

    let prefixCharacters = mainPrefix.map(String.init)
    let first = prefixCharacters.first ?? ""
    let second = prefixCharacters.dropFirst().first ?? ""
    let third = prefixCharacters.dropFirst(2).first ?? ""

    switch mainPrefix.count {
    case 1:
      if oneCharPrefixes.contains(first) {
        // I9MRY/1 - mainPrefix = I --> I1
        position = 2
      } else if mainPrefix.isAlphabetic {
        // FA3L/6 - mainPrefix is F
        position = 99
        return ""
      }

    case 2:
      if oneCharPrefixes.contains(first)
        && digitSymbols.contains(second) {
        // W6OP/4 - main prefix = W6 --> W4
        position = 2
      } else {
        // AL7NS/4 - main prefix = KL --> KL4
        position = 3
      }

    default:
      if oneCharPrefixes.contains(first)
        && digitSymbols.contains(second) {
        position = 2
      } else {
        if digitSymbols.contains(third) {
          // JI3DT/6 - mainPrefix = JA3 --> JA6
          position = 3
        } else {
          // 3DLE/1 - mainprefix = 3DA --> 3DA1
          position = 4
        }
      }
    }

    // append call area to mainPrefix
    return mainPrefix.prefix(position - 1) + prefix + "/"
  }

} // end extension
