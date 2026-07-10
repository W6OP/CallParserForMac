//
//  CallLookup.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

//import Algorithms
import Foundation
import os

// MARK: Class Implementation

/// Parse a call sign and return an object describing the country, dxcc, etc.
public final class CallLookup: Sendable {

  let logger = Logger(subsystem: "com.w6op.CallParser", category: "CallLookup")

  /// Actors
  let hitCache: HitCache<String, Hit>
  let qrzSession = QRZSession()

  /// Configuration -- captured at init, immutable for the lifetime of the lookup.
  public let useCallParserOnly: Bool
  public let verboseLogging: Bool

  /// Immutable after init -- safe for concurrent reads
  let adifs: [Int: PrefixData]
  let dxccEntities: [Int: String]
  /// Bitset-based mask index built by ``PrefixFileParser/parse()``.
  let bitsetIndex: BitsetMaskIndex
  /// Shape patterns of all registered portable masks (e.g. `"@@/"`, `"@@#/"`).
  /// ``CallStructure`` uses this set to gate whether a 2-or-more-character
  /// alpha/digit sequence should be treated as a known portable prefix.
  let portablePrefixShapePatterns: Set<String>
  let cacheMaxCapacity: Int = 10000

  /// Parsed BigCTY data, guarded by an unfair lock for safe cross-actor mutation.
  private let _bigCTYData = OSAllocatedUnfairLock<BigCTYData?>(initialState: nil)

  /// Parsed BigCTY data loaded from Application Support, if available.
  public var bigCTYData: BigCTYData? {
    get { _bigCTYData.withLock { $0 } }
    set { _bigCTYData.withLock { $0 = newValue } }
  }

  // MARK: - Initializers

  /// Designated initializer.
  /// - Parameters:
  ///   - parsedData: Immutable prefix tables produced by ``PrefixFileParser/parse()``.
  ///   - useCallParserOnly: When `true`, QRZ.com lookups are skipped even if a session is active.
  ///   - verboseLogging: When `true`, emits diagnostic log lines for each lookup.
  public init(
    parsedData: ParsedPrefixData,
    useCallParserOnly: Bool = false,
    verboseLogging: Bool = false
  ) {
    self.useCallParserOnly = useCallParserOnly
    self.verboseLogging = verboseLogging
    self.hitCache = HitCache(maxCapacity: cacheMaxCapacity)
    self.adifs = parsedData.adifs
    self.bitsetIndex = parsedData.bitsetIndex
    self.portablePrefixShapePatterns = parsedData.portablePrefixShapePatterns
    self.dxccEntities = Self.loadDXCCEntities()

    loadBigCTYData()
  }

  /// Default constructor — produces an empty lookup. Real use should pass
  /// the result of ``PrefixFileParser/parse()``.
  public convenience init() {
    self.init(parsedData: ParsedPrefixData(adifs: [:]))
  }

  /// Loads BigCTY data from Application Support if a previously downloaded file exists.
  private func loadBigCTYData() {
    do {
      let loaded = try loadBigCTYFromDisk()
      bigCTYData = loaded
      if loaded != nil {
        logger.log("BigCTY data loaded on init")
      }
    } catch {
      logger.error("Failed to load BigCTY data: \(error.localizedDescription)")
    }
  }

  /// Clears all entries from the hit cache asynchronously.
  public func clearLookupCache() async {
    await hitCache.clearCache()
  }

}  // end class

extension CallLookup {
  // MARK: QRZ Session Delegation

  /// Logs in to QRZ.com to obtain a session key.
  /// - Parameters:
  ///   - userId: QRZ.com username.
  ///   - password: QRZ.com password.
  ///   - forceRenewal: Whether to discard any cached session key and request a new one.
  ///     Repeating logon while a session is active also renews the session.
  /// - Returns: `true` if login and session key retrieval succeeded.
  /// - Throws: `QRZManagerError` on failure.
  public func logonToQrz(
    userId: String,
    password: String,
    forceRenewal: Bool = false
  ) async throws -> Bool {
    try await qrzSession.logon(userId: userId, password: password, forceRenewal: forceRenewal)
  }

  /// Clears the local QRZ session, cancelling any in-flight renewal.
  ///
  /// Safe to call from app-termination hooks; the underlying actor work is
  /// purely in-memory state clearing.
  public func logoffFromQrz() async {
    await qrzSession.logoff()
  }
}

// MARK: Lookup Call

public struct CallPairHits {
  public let spotter: [Hit]
  public let dx: [Hit]
}

extension CallLookup {

  /// Performs two lookups for spotter and DX call signs.
  /// - Parameters:
  ///   - spotter: The spotting station call sign.
  ///   - dx: The DX station call sign.
  /// - Returns: Combined array of `Hit` results.
  @available(*, deprecated, message: "Use lookupCallPairGrouped(spotter:dx:) which returns CallPairHits with separate spotter and dx results.")
  public func lookupCallPair(spotter: String, dx: String) async -> [Hit] {

    async let spotterStation = lookupCall(callSign: spotter)
    async let dxStation = lookupCall(callSign: dx)

    return await spotterStation + dxStation
  }

  /// Looks up a pair of call signs in parallel and returns the results grouped by role.
  /// - Parameters:
  ///   - spotter: The spotting station call sign.
  ///   - dx: The DX station call sign.
  /// - Returns: A ``CallPairHits`` containing separate spotter and dx hit arrays.
  public func lookupCallPairGrouped(
    spotter: String,
    dx: String
  ) async -> CallPairHits {

    async let spotterHits = lookupCall(callSign: spotter)
    async let dxHits = lookupCall(callSign: dx)

    return await CallPairHits(
      spotter: spotterHits,
      dx: dxHits
    )
  }

  /// Looks up multiple call signs concurrently using a TaskGroup with bounded parallelism.
  ///
  /// Results are returned as a dictionary keyed by the original call sign string.
  /// Duplicate call signs in the input are deduplicated automatically.
  ///
  /// - Parameters:
  ///   - callSigns: The call signs to look up.
  ///   - maxConcurrency: Maximum number of concurrent lookups (default 8).
  /// - Returns: A dictionary mapping each call sign to its `[Hit]` results.
  public func lookupBatch(
    callSigns: [String],
    maxConcurrency: Int = 8
  ) async -> [String: [Hit]] {
    await withTaskGroup(of: (String, [Hit]).self) { group in
      var results = [String: [Hit]]()
      var inFlight = 0
      var index = callSigns.startIndex

      while index < callSigns.endIndex || !group.isEmpty {
        // Launch tasks up to maxConcurrency
        while inFlight < maxConcurrency && index < callSigns.endIndex {
          let call = callSigns[index]
          group.addTask {
            (call, await self.lookupCall(callSign: call))
          }
          inFlight += 1
          index = callSigns.index(after: index)
        }
        // Collect one result before launching more
        if let (call, hits) = await group.next() {
          results[call] = hits
          inFlight -= 1
        }
      }
      return results
    }
  }

  /// Parses a single call sign using only the local prefix data.
  ///
  /// This is a **synchronous** fast path — no cache reads/writes, no QRZ,
  /// no actor hops. Ideal for high-throughput batch processing.
  ///
  /// - Parameter callSign: The call sign to parse.
  /// - Returns: Array of `Hit` results (usually one element).
  public func parseCallSign(_ callSign: String) -> [Hit] {
    let cleaned = cleanCallSign(callSign: callSign)
    guard !cleaned.isEmpty else { return [] }
    let lookup = stripOperationalSuffix(from: cleaned)
    return processCallSign(call: lookup)
  }

  /// Parses multiple call signs concurrently using chunk-based parallelism.
  ///
  /// Divides the work into one chunk per CPU core, each processed synchronously
  /// to eliminate per-call async overhead. No cache or QRZ lookups are performed.
  ///
  /// - Parameter callSigns: The call signs to parse.
  /// - Returns: A dictionary mapping each call sign to its `[Hit]` results.
  public func parseBatch(callSigns: [String]) async -> [String: [Hit]] {
    let coreCount = ProcessInfo.processInfo.activeProcessorCount
    let chunkSize = max(1, (callSigns.count + coreCount - 1) / coreCount)

    return await withTaskGroup(of: [(String, [Hit])].self) { group in
      for start in stride(from: 0, to: callSigns.count, by: chunkSize) {
        let end = min(start + chunkSize, callSigns.count)
        let chunk = callSigns[start..<end]
        group.addTask {
          chunk.map { call in (call, self.parseCallSign(call)) }
        }
      }

      var results = [String: [Hit]]()
      results.reserveCapacity(callSigns.count)
      for await chunkResults in group {
        for (call, hits) in chunkResults {
          results[call] = hits
        }
      }
      return results
    }
  }

  /// Looks up metadata for a single call sign, using cache, QRZ lookup, or local parser.
  /// - Parameter callSign: The call sign to lookup.
  /// - Returns: Array of `Hit` results (usually one element).
  public func lookupCall(callSign: String) async -> [Hit] {
    var hits: [Hit] = []
    let callSign = cleanCallSign(callSign: callSign)

    guard callSign.isEmpty == false else {
      return hits
    }

    // Strip operational suffixes (/P, /M, etc.) for lookups only — not for display
    let lookupCall = stripOperationalSuffix(from: callSign)

    if let hit = await hitCache.checkCache(callSign) {
      hits.append(hit)
      if verboseLogging {
        logger.log("\(callSign) retrieved from cache")
      }
      return hits
    }

    let sessionActive = await qrzSession.isActive
    if sessionActive && !useCallParserOnly {
      if let dictionary = await qrzSession.fetchCallSignData(call: lookupCall, verboseLogging: verboseLogging) {
        let hit = buildHit(callSignDictionary: dictionary)
        hits.append(hit)
        await hitCache.updateCache(hit.call, value: hit)
        if verboseLogging {
          logger.log("\(callSign) retrieved from QRZ")
        }
      } else {  // QRZ fetch failed -- fall back to local parser (not cached)
        let hitCollection = resolveLocally(call: lookupCall)
        hits.append(contentsOf: hitCollection)
        if verboseLogging {
          logger.log("\(callSign) retrieved from call parser (not cached, QRZ fallback)")
        }
      }

      if verboseLogging {
        let cacheInfo = await hitCache.cacheHitMissRatio()
        logger.log(
          "cache hits: \(cacheInfo.hits) - misses: \(cacheInfo.misses) - ratio: \(Int(cacheInfo.ratio * 100))%"
        )
        let count = await hitCache.count
        logger.log("cache size: \(count)")
      }

      return hits
    }

    // No QRZ session -- use local parser only, cache the results.
    // Cache key is the original cleaned call sign (matching the check key
    // on entry) so that distinct full calls such as "BU7JP" and "BU7JP/P"
    // get distinct cache entries even though they share an internal parse.
    let hitCollection = resolveLocally(call: lookupCall)
    hits.append(contentsOf: hitCollection)
    for hit in hitCollection {
      await hitCache.updateCache(callSign, value: hit)
    }
    if verboseLogging {
      logger.log("\(callSign) retrieved from call parser")
    }

    return hits
  }
}

// QRZ Call Sign Data Request logic has been moved to QRZSession actor.

// MARK: - Benchmarking primitives (candidate finding, no Hit construction)
//
// Returns the matched `[PrefixData]` for a callsign without constructing
// `Hit`s. Useful for micro-benchmarking the mask-match primitive in
// isolation from the result-assembly cost.

extension CallLookup {

  /// Candidate finder. Cleans input, then runs the bit-encoded per-position
  /// match against ``BitsetMaskIndex``.
  ///
  /// - Parameter callSign: Raw user input — cleaning is performed internally.
  /// - Returns: Every ``PrefixData`` whose compiled mask accepts the call.
  public func candidates(for callSign: String) -> [PrefixData] {
    let cleaned = cleanCallSign(callSign: callSign)
    guard !cleaned.isEmpty else { return [] }
    let lookup = stripOperationalSuffix(from: cleaned)
    return candidatesRaw(forCleaned: lookup)
  }

  /// Pre-cleaned candidate finder — assumes input is already uppercased and
  /// has had operational suffixes stripped. Builds a ``CallStructure`` to
  /// extract the correct prefix/base candidate before bitset lookup so
  /// compound calls like `KF6ZWD/HC2` are matched on the right component.
  public func candidatesRaw(forCleaned cleanedCall: String) -> [PrefixData] {
    let callStructure = CallStructure(
      callSign: cleanedCall,
      portablePrefixShapePatterns: portablePrefixShapePatterns
    )
    guard callStructure.callStructureType != .invalid else { return [] }
    return searchMainDictionary(structure: callStructure)
  }

  /// Public counterpart to the internal ``cleanCallSign(callSign:)`` /
  /// ``stripOperationalSuffix(from:)`` pair. Returns the call ready to be
  /// fed into the `*Raw` primitives, or `nil` if it is unusable.
  public func preCleanCallSign(_ callSign: String) -> String? {
    let cleaned = cleanCallSign(callSign: callSign)
    guard !cleaned.isEmpty else { return nil }
    return stripOperationalSuffix(from: cleaned)
  }

  /// Number of compiled mask entries in the bitset index.
  ///
  /// A single mask whose first position accepts N characters contributes N
  /// entries (one per first-char bucket). Useful for sanity-checking that
  /// the index loaded correctly.
  public var bitsetIndexEntryCount: Int { bitsetIndex.entryCount }

  /// Benchmark batch. Returns per-call candidate count. Same chunked
  /// concurrency as ``parseBatch(callSigns:)`` — exercises only candidate
  /// finding, no ``Hit`` construction.
  public func candidatesBatch(callSigns: [String]) async -> [String: Int] {
    let coreCount = ProcessInfo.processInfo.activeProcessorCount
    let chunkSize = max(1, (callSigns.count + coreCount - 1) / coreCount)

    return await withTaskGroup(of: [(String, Int)].self) { group in
      for start in stride(from: 0, to: callSigns.count, by: chunkSize) {
        let end = min(start + chunkSize, callSigns.count)
        let chunk = callSigns[start..<end]
        group.addTask {
          chunk.map { call in (call, self.candidates(for: call).count) }
        }
      }

      var results = [String: Int]()
      results.reserveCapacity(callSigns.count)
      for await chunkResults in group {
        for (call, count) in chunkResults {
          results[call] = count
        }
      }
      return results
    }
  }
}

// MARK: - Load files

extension CallLookup {

  /// Loads call signs from a bundled CSV resource owned by the package.
  /// - Parameter dataSet: Which bundled CSV to load.
  /// - Returns: An array of non-empty call sign strings.
  public static func loadCallSigns(from dataSet: BenchmarkDataSet) -> [String] {
    loadCallSigns(from: dataSet, in: .module)
  }

  /// Loads call signs from a bundled CSV resource.
  /// - Parameters:
  ///   - dataSet: Which bundled CSV to load.
  ///   - bundle: The bundle that owns the CSV resource.
  /// - Returns: An array of non-empty call sign strings.
  public static func loadCallSigns(from dataSet: BenchmarkDataSet, in bundle: Bundle) -> [String] {
    guard
      let url = bundle.url(
        forResource: dataSet.resourceName,
        withExtension: "csv"
      )
    else {
      return []
    }
    do {
      let contents = try String(contentsOf: url, encoding: .utf8)
      return contents
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    } catch {
      return []
    }
  }

  static func loadDXCCEntities() -> [Int: String] {
    guard
      let url = Bundle.module.url(
        forResource: "dxccEntities",
        withExtension: "csv"
      )
    else {
      return [:]
    }
    do {
      let contents = try String(contentsOf: url, encoding: .utf8)
      let lines = contents.components(separatedBy: .newlines)

      var entities = [Int: String]()
      for callSign in lines {
        let components = callSign.split(separator: ",")
        if components.count > 1 {
          entities[Int(components[1]) ?? 0] = String(components[0])
        }
      }
      return entities
    } catch {
      print("Invalid entity file: ")
      return [:]
    }
  }
}

extension CallLookup {
  // MARK: - Clean Callsign

  /// Cleans and normalizes a raw call sign by trimming whitespace, removing illegal characters, and uppercasing.
  ///
  /// Single-pass UTF-8 scan: trims outer ASCII whitespace, rejects interior
  /// space or `%`, strips control characters, drops leading/trailing `/`,
  /// collapses runs of `/`, and uppercases ASCII letters. Allocates one
  /// `[UInt8]` buffer plus the returned `String` — no intermediate Foundation
  /// `trimmingCharacters` / `replacingOccurrences` / `uppercased()` copies.
  ///
  /// - Parameter callSign: Raw input call sign.
  /// - Returns: A cleaned, uppercase call sign without leading/trailing slashes.
  func cleanCallSign(callSign: String) -> String {
    let view = callSign.utf8
    guard !view.isEmpty else { return "" }

    // Trim leading ASCII whitespace.
    var startIdx = view.startIndex
    while startIdx < view.endIndex, Self.isAsciiWhitespace(view[startIdx]) {
      startIdx = view.index(after: startIdx)
    }

    // Trim trailing ASCII whitespace.
    var endIdx = view.endIndex
    while endIdx > startIdx {
      let prev = view.index(before: endIdx)
      if !Self.isAsciiWhitespace(view[prev]) { break }
      endIdx = prev
    }

    if startIdx == endIdx { return "" }

    var result: [UInt8] = []
    result.reserveCapacity(view.distance(from: startIdx, to: endIdx))

    var pendingSlash = false
    var hasContent = false
    var idx = startIdx
    while idx < endIdx {
      let byte = view[idx]
      idx = view.index(after: idx)

      switch byte {
      case 0x20:                    // interior space — reject
        return ""
      case 0x25:                    // '%' — reject
        return ""
      case 0x00...0x1F, 0x7F:       // control characters — strip
        continue
      case 0x2F:                    // '/'
        if hasContent { pendingSlash = true }   // skip leading, collapse runs
        continue
      case 0x61...0x7A:             // 'a'..'z' → uppercase
        if pendingSlash { result.append(0x2F); pendingSlash = false }
        result.append(byte &- 0x20)
        hasContent = true
      default:                      // letters, digits, other allowed bytes
        if pendingSlash { result.append(0x2F); pendingSlash = false }
        result.append(byte)
        hasContent = true
      }
    }

    // Trailing '/' implicitly dropped: pendingSlash never written when
    // followed by no more content.
    return String(decoding: result, as: UTF8.self)
  }

  /// Returns `true` for ASCII space, tab, line feed, vertical tab,
  /// form feed, or carriage return — the same set treated as
  /// "whitespace and newlines" for trimming purposes on callsign input.
  @inline(__always)
  private static func isAsciiWhitespace(_ byte: UInt8) -> Bool {
    return byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
  }

  /// Strips operational suffixes that don't change station identity.
  /// Used before QRZ and call parser lookups but NOT for display.
  /// Examples: DL8ECA/P → DL8ECA, W6OP/QRP → W6OP
  ///
  /// Also tolerates malformed inputs where a stray digit was typed in front
  /// of a valid suffix (e.g. `OE5OZL/5MM` → `OE5OZL`). Maritime mobile and
  /// other operational suffixes have no district number, so a leading digit
  /// in the suffix is always a typo and the whole tail is discarded.
  ///
  /// Assumes the input is already uppercase ASCII (guaranteed by the upstream
  /// ``cleanCallSign(callSign:)`` step). Works directly on the UTF-8 view so
  /// no intermediate `String` is allocated unless an actual strip happens.
  func stripOperationalSuffix(from callSign: String) -> String {
    let view = callSign.utf8
    guard view.count >= 2 else { return callSign }

    // Walk backwards to find the last '/' (0x2F).
    var slashIdx = view.endIndex
    var found = false
    while slashIdx > view.startIndex {
      slashIdx = view.index(before: slashIdx)
      if view[slashIdx] == 0x2F { found = true; break }
    }
    guard found else { return callSign }

    let afterSlash = view.index(after: slashIdx)
    let bareLen = view.distance(from: afterSlash, to: view.endIndex)

    // Exact suffix match against the bare tail (after '/').
    if Self.matchesOperationalSuffix(view, start: afterSlash, length: bareLen) {
      return String(callSign.dropLast(bareLen + 1))
    }

    // Malformed-suffix recovery: '/<digit><valid suffix>' (e.g. /5MM, /4P).
    // The leading digit is meaningless for operational suffixes, so the
    // whole tail is discarded.
    if bareLen >= 2, Self.isAsciiDigit(view[afterSlash]) {
      let suffixStart = view.index(after: afterSlash)
      if Self.matchesOperationalSuffix(view, start: suffixStart, length: bareLen - 1) {
        return String(callSign.dropLast(bareLen + 1))
      }
    }

    return callSign
  }

  /// Returns `true` if the bytes at `start..<start+length` in `view` form
  /// one of the seven valid operational suffix bare-tails: `P`, `M`, `MM`,
  /// `AM`, `DX`, `QRP`, `QRO`. Byte-level switch avoids the cost of building
  /// a `Set<String>` and stringifying the candidate for membership lookup.
  @inline(__always)
  private static func matchesOperationalSuffix(
    _ view: String.UTF8View,
    start: String.UTF8View.Index,
    length: Int
  ) -> Bool {
    switch length {
    case 1:
      let b = view[start]
      return b == 0x50 || b == 0x4D                       // P, M
    case 2:
      let b0 = view[start]
      let b1 = view[view.index(after: start)]
      // MM, AM, DX
      return (b0 == 0x4D && b1 == 0x4D)
          || (b0 == 0x41 && b1 == 0x4D)
          || (b0 == 0x44 && b1 == 0x58)
    case 3:
      var idx = start
      let b0 = view[idx]; idx = view.index(after: idx)
      let b1 = view[idx]; idx = view.index(after: idx)
      let b2 = view[idx]
      // QRP, QRO
      return b0 == 0x51 && b1 == 0x52 && (b2 == 0x50 || b2 == 0x4F)
    default:
      return false
    }
  }

  @inline(__always)
  private static func isAsciiDigit(_ byte: UInt8) -> Bool {
    return byte >= 0x30 && byte <= 0x39
  }
}

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
    for ch in candidate {
      guard let b = CallSymbol.bit(for: ch) else { return [] }
      bits.append(UInt64(1) << UInt64(b))
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
    var p = prefix
    if !p.hasSuffix("/") { p += "/" }
    guard let bits = p.toCallBits() else { return [] }
    let portable = bitsetIndex.candidates(for: bits)
    if !portable.isEmpty { return portable }

    let bare = String(p.dropLast())
    if let bareBits = bare.toCallBits() {
      let bareMatches = bitsetIndex.candidates(for: bareBits)
      if !bareMatches.isEmpty { return bareMatches }
    }

    let lettersOnly = p.prefix { $0.isLetter }
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
  func buildHit(foundItems: [PrefixData], callStructure: CallStructure) -> [Hit]
  {
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

    if callStructure.prefix == String(digits[0]) {
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
  func replaceCallArea(mainPrefix: String, prefix: String) -> String
  {
    var position = 0
    let oneCharPrefixes: [String] = ["I", "K", "N", "W", "R", "U"]
    let XNUM_SET: [String] = [
      "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "#", "[",
    ]

    switch mainPrefix.count {
    case 1:
      if oneCharPrefixes.contains(mainPrefix[0]) {
        // I9MRY/1 - mainPrefix = I --> I1
        position = 2
      } else if mainPrefix.isAlphabetic {
        // FA3L/6 - mainPrefix is F
        position = 99
        return ""
      }

    case 2:
      if oneCharPrefixes.contains(mainPrefix[0])
        && XNUM_SET.contains(mainPrefix[1])
      {
        // W6OP/4 - main prefix = W6 --> W4
        position = 2
      } else {
        // AL7NS/4 - main prefix = KL --> KL4
        position = 3
      }

    default:
      if oneCharPrefixes.contains(mainPrefix[0])
        && XNUM_SET.contains(mainPrefix[1])
      {
        position = 2
      } else {
        if XNUM_SET.contains(mainPrefix[2]) {
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

