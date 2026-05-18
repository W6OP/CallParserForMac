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
  let callSignPatterns: [String: [PrefixData]]
  let portablePrefixes: [String: [PrefixData]]
  let dxccEntities: [Int: String]
  let mergeHits = false
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
    self.callSignPatterns = parsedData.callSignPatterns
    self.portablePrefixes = parsedData.portablePrefixPatterns
    self.adifs = parsedData.adifs
    self.dxccEntities = Self.loadDXCCEntities()

    loadBigCTYData()
  }

  /// Initialization with a QRZ user name and password.
  ///
  /// After init, call `logonToQrz(userId:password:)` to establish a session.
  /// - Parameter prefixFileParser: PrefixFileParser
  @available(*, deprecated, message: "Use init(parsedData:useCallParserOnly:verboseLogging:) with PrefixFileParser.parse(). The qrzUserId/qrzPassword parameters were unused; call logonToQrz(userId:password:) separately.")
  public convenience init(
    prefixFileParser: PrefixFileParser,
    qrzUserId: String,
    qrzPassword: String
  ) {
    let parsed = ParsedPrefixData(
      callSignPatterns: prefixFileParser.callSignPatterns,
      portablePrefixPatterns: prefixFileParser.portablePrefixPatterns,
      adifs: prefixFileParser.adifs
    )
    self.init(parsedData: parsed)
  }

  /// Initialization without a QRZ user name and password.
  /// - Parameter prefixFileParser: PrefixFileParser
  @available(*, deprecated, message: "Use init(parsedData:useCallParserOnly:verboseLogging:) with PrefixFileParser.parse() for a Sendable-clean call site.")
  public convenience init(prefixFileParser: PrefixFileParser) {
    let parsed = ParsedPrefixData(
      callSignPatterns: prefixFileParser.callSignPatterns,
      portablePrefixPatterns: prefixFileParser.portablePrefixPatterns,
      adifs: prefixFileParser.adifs
    )
    self.init(parsedData: parsed)
  }

  /// Default constructor.
  public convenience init() {
    self.init(
      parsedData: ParsedPrefixData(
        callSignPatterns: [:],
        portablePrefixPatterns: [:],
        adifs: [:]
      )
    )
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
  /// - Returns: `true` if login and session key retrieval succeeded.
  /// - Throws: `QRZManagerError` on failure.
  public func logonToQrz(userId: String, password: String) async throws -> Bool {
    try await qrzSession.logon(userId: userId, password: password)
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
        let hitCollection = processCallSign(call: lookupCall)
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
    let hitCollection = processCallSign(call: lookupCall)
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
  /// - Parameter callSign: Raw input call sign.
  /// - Returns: A cleaned, uppercase call sign without leading/trailing slashes.
  func cleanCallSign(callSign: String) -> String {

    var cleanedCallSign = String(
      callSign.trimmingCharacters(in: .whitespacesAndNewlines)
    )

    // if there are spaces in the call don't process it
    guard !cleanedCallSign.contains(" ") else {
      // SHOULD THROW
      return ""
    }

    guard !cleanedCallSign.contains("%") else {
      return ""
    }

    // don't use switch here as multiple conditions may exist
    // strip leading or trailing "/"  /W6OP/
    if cleanedCallSign.prefix(1) == "/" {
      cleanedCallSign = String(
        cleanedCallSign.suffix(cleanedCallSign.count - 1)
      )
    }

    if cleanedCallSign.suffix(1) == "/" {
      cleanedCallSign = String(
        cleanedCallSign.prefix(cleanedCallSign.count - 1)
      )
    }

    if cleanedCallSign.contains("///") {  // BU1H8///D
      cleanedCallSign = cleanedCallSign.replacingOccurrences(
        of: "///",
        with: "/"
      )
    }

    if cleanedCallSign.contains("//") {  // EB5KB//P
      cleanedCallSign = cleanedCallSign.replacingOccurrences(
        of: "//",
        with: "/"
      )
    }

    return cleanedCallSign.trimmingCharacters(in: .controlCharacters)
      .uppercased()
  }

  /// Strips operational suffixes that don't change station identity.
  /// Used before QRZ and call parser lookups but NOT for display.
  /// Examples: DL8ECA/P → DL8ECA, W6OP/QRP → W6OP
  func stripOperationalSuffix(from callSign: String) -> String {
    let operationalSuffixes: Set<String> = [
      "/P", "/M", "/MM", "/AM", "/QRP", "/QRO", "/DX"
    ]

    let upper = callSign.uppercased()
    for suffix in operationalSuffixes {
      if upper.hasSuffix(suffix) {
        return String(callSign.dropLast(suffix.count))
      }
    }
    return callSign
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
      portablePrefixes: portablePrefixes
    )
    guard callStructure.callStructureType != .invalid else { return [] }
    return collectMatches(callStructure: callStructure)
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

    matches = searchMainDictionary(structure: callStructure, saveHit: true)
    return buildHit(foundItems: matches, callStructure: callStructure)
  }

  /// Searches the main prefix dictionary for matching `PrefixData`.
  /// - Parameters:
  ///   - structure: The call structure guiding the search.
  ///   - saveHit: Whether to record the match via `matchesFound`.
  /// - Returns: Array of matching `PrefixData`.
  func searchMainDictionary(structure: CallStructure, saveHit: Bool)
    -> [PrefixData]
  {
    var callStructure = structure
    let baseCall = callStructure.baseCall

    var firstFourCharacters = (
      firstLetter: "", secondLetter: "", thirdLetter: "", fourthLetter: ""
    )
    let pattern = determinePatternToUse(
      callStructure: &callStructure,
      firstFourCharacters: &firstFourCharacters
    )
    var stopCharacterFound = false
    let prefixDataList = matchPattern(
      pattern: pattern,
      firstFourCharacters: firstFourCharacters,
      callPrefix: callStructure.prefix!,
      stopCharacterFound: &stopCharacterFound
    )

    let localMatches: [PrefixData]
    if prefixDataList.isEmpty {
      return []
    } else if prefixDataList.count == 1 {
      localMatches = prefixDataList
    } else {
      localMatches = prefixDataList.flatMap { prefixData in
        let maskList = prefixData.getMaskList(
          first: firstFourCharacters.firstLetter,
          second: firstFourCharacters.secondLetter,
          stopCharacterFound: stopCharacterFound
        )
        return refineList(
          baseCall: baseCall!,
          prefixData: prefixData,
          primaryMaskList: maskList
        )
      }
    }

    if saveHit {
      _ = matchesFound(saveHit: true, matches: localMatches)
    }

    return localMatches
  }

} // end extension

extension CallLookup {
  // MARK: - Determine the pattern and mask to search with.

  /// Determines the search pattern and mask components for a call structure.
  /// - Parameters: ...
  /// - Returns: ...
  func determinePatternToUse(
    callStructure: inout CallStructure,
    firstFourCharacters: inout (
      firstLetter: String,
      secondLetter: String,
      thirdLetter: String,
      fourthLetter: String
    )
  ) -> String {
    // Choose the prefix candidate based on the structure type
    let candidate: String
    switch callStructure.callStructureType {
    case .prefixCall, .prefixCallPortable, .prefixCallText:
      // Use existing prefix if present
      candidate = callStructure.prefix ?? callStructure.baseCall
    default:
      // Fallback to baseCall and update prefix
      callStructure.prefix = callStructure.baseCall
      candidate = callStructure.baseCall
    }

    // Compute mask components once
    firstFourCharacters = determineMaskComponents(prefix: candidate)

    // Build and return the pattern
    return callStructure.buildPattern(candidate: candidate)
  }

  /// Extracts up to the first four characters of `prefix` as single-character strings.
  func determineMaskComponents(prefix: String) -> (
    String, String, String, String
  ) {
    var first = "", second = "", third = "", fourth = ""
    var iter = prefix.unicodeScalars.makeIterator()
    if let c = iter.next() { first = String(c) } else { return (first, second, third, fourth) }
    if let c = iter.next() { second = String(c) }
    if let c = iter.next() { third = String(c) }
    if let c = iter.next() { fourth = String(c) }
    return (first, second, third, fourth)
  }

  // MARK: - Matching Patterns

  /// Refines a set of mask lists into `PrefixData` hits based on matching character positions.
  /// - Parameters:
  ///   - baseCall: The full call string.
  ///   - prefixData: Initial `PrefixData` to refine.
  ///   - primaryMaskList: Set of possible masks.
  /// - Returns: Filtered and ranked array of `PrefixData`.
  func refineList(
    baseCall: String,
    prefixData: PrefixData,
    primaryMaskList: Set<[[String]]>
  ) -> [PrefixData] {
    var matches = [PrefixData]()
    // Pre-convert to [String] once to avoid per-comparison String(Character) allocations
    let baseStrings = baseCall.unicodeScalars.map { String($0) }

    for mask in primaryMaskList {
      let maxIndex = min(mask.count, baseStrings.count)
      var matchLength = 0
      for i in 2..<maxIndex {
        if mask[i].contains(baseStrings[i]) {
          matchLength += 1
        } else {
          break
        }
      }
      let rank = (matchLength > 0) ? matchLength + 2 : 1
      if mask.count == 2 || rank == maxIndex {
        var data = prefixData
        data.searchRank = rank
        matches.append(data)
      }
    }
    return matches
  }

  /// Handles saving or merging hits and returns a main prefix string.
  /// - Parameters:
  ///   - saveHit: Whether to save the hit.
  ///   - matches: Matched `PrefixData` array.
  /// - Returns: The main prefix string or empty if multiple/merged.
  func matchesFound(saveHit: Bool, matches: [PrefixData]) -> String {

    if saveHit == false {
      return matches.first?.mainPrefix ?? ""
    } else {
      if !mergeHits || matches.count == 1 {
        return ""
      } else {
        print("Multiple hits found")
      }
    }

    return ""
  }

  /// Iteratively matches decreasing patterns against the prefix dictionary until hits are found.
  /// - Returns: Array of `PrefixData` for the first match set.
  func matchPattern(
    pattern: String,
    firstFourCharacters: (
      firstLetter: String, secondLetter: String, thirdLetter: String,
      fourthLetter: String
    ),
    callPrefix: String,
    stopCharacterFound: inout Bool
  ) -> [PrefixData] {

    var prefixDataList = [PrefixData]()
    let prefix = callPrefix
    var modifiedPattern = pattern + "."
    var patternLength = modifiedPattern.utf8.count
    stopCharacterFound = false

    while patternLength > 1 {
      // Access query if available, or trim pattern and continue
      guard let query = callSignPatterns[modifiedPattern] else {
        modifiedPattern.removeLast()
        patternLength -= 1
        continue
      }

      for var prefixData in query {
        // Filter by primary and secondary index keys first
        if prefixData.primaryIndexKey.contains(firstFourCharacters.firstLetter),
          prefixData.secondaryIndexKey.contains(
            firstFourCharacters.secondLetter
          )
        {

          // Apply conditional checks on tertiary and quaternary index keys
          if patternLength >= 3,
            !prefixData.tertiaryIndexKey.contains(
              firstFourCharacters.thirdLetter
            )
          {
            continue
          }
          if patternLength >= 4,
            !prefixData.quatinaryIndexKey.contains(
              firstFourCharacters.fourthLetter
            )
          {
            continue
          }

          // Determine prefix for setSearchRank based on the last character of modifiedPattern
          let isStopCharacter = modifiedPattern.last == "."
          let prefixLength = isStopCharacter ? patternLength - 1 : patternLength
          let searchPrefix = String(prefix.prefix(prefixLength))

          // Set search rank and add to list if successful
          var searchRank = 0
          if prefixData.setSearchRank(
            prefix: searchPrefix,
            excludePortablePrefixes: true,
            searchRank: &searchRank
          ) {
            prefixData.searchRank = searchRank

            // If stop character found, append to list and exit early
            if isStopCharacter {
              prefixDataList.append(prefixData)
              stopCharacterFound = true
              return prefixDataList
            }

            // Append unique prefix data if not a duplicate
            if !prefixDataList.contains(where: { $0 == prefixData }) {
              prefixDataList.append(prefixData)
            }
          }
        }
      }
      modifiedPattern.removeLast()
      patternLength -= 1
    }

    return prefixDataList
  }
}

// MARK: - Portable Prefixes

extension CallLookup {

  /// Checks for portable-prefix formats (e.g., VK4AAA/3) and returns hits.
  func checkForPortablePrefix(callStructure: CallStructure) -> [Hit]? {
    guard var prefix = callStructure.prefix else { return nil }
    if !prefix.hasSuffix("/") {
      prefix += "/"
    }

    let pattern = callStructure.buildPattern(candidate: prefix)
    let candidates = getPortablePrefixes(
      prefix: prefix,
      patternBuilder: pattern
    )

    guard !candidates.isEmpty else { return nil }

    let topMatches: [PrefixData]
    if candidates.count == 1 {
      topMatches = candidates
    } else {
      let maxRank = candidates.lazy.map(\.searchRank).max()!
      topMatches = candidates.filter { $0.searchRank == maxRank }
    }

    return buildHit(foundItems: topMatches, callStructure: callStructure)
  }

  /// Retrieves portable prefix entries matching the given pattern and ranks them.
  func getPortablePrefixes(prefix: String, patternBuilder: String)
    -> [PrefixData]
  {
    // Quick exit if no candidates
    guard let candidates = portablePrefixes[patternBuilder], !candidates.isEmpty
    else {
      return []
    }

    // Pre-extract characters once
    let first = prefix[prefix.startIndex]
    let second =
      prefix.index(prefix.startIndex, offsetBy: 1, limitedBy: prefix.endIndex)
      .map { prefix[$0] } ?? prefix[prefix.startIndex]
    let third =
      prefix.count > 2
      ? prefix[prefix.index(prefix.startIndex, offsetBy: 2)] : first
    let fourth =
      prefix.count > 3
      ? prefix[prefix.index(prefix.startIndex, offsetBy: 3)] : second

    var bestRank = 0
    var results = [PrefixData]()

    for var prefixData in candidates {
      // Filter by index keys
      guard prefixData.primaryIndexKey.contains(String(first)),
        prefixData.secondaryIndexKey.contains(String(second)),
        prefix.count < 3 || prefixData.tertiaryIndexKey.contains(String(third)),
        prefix.count < 4
          || prefixData.quatinaryIndexKey.contains(String(fourth))
      else {
        continue
      }

      var rank = 0
      if prefixData.setSearchRank(
        prefix: prefix,
        excludePortablePrefixes: false,
        searchRank: &rank
      ) {
        prefixData.searchRank = rank

        // Keep only the highest-ranked matches
        if rank > bestRank {
          bestRank = rank
          results = [prefixData]
        } else if rank == bestRank {
          results.append(prefixData)
        }
      }
    }

    return results
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
    var hitList: [Hit] = []
    let call = callStructure.fullCall

    let listByRank = foundItems.sorted(by: {
      (prefixData0: PrefixData, prefixData1: PrefixData) -> Bool in
      return prefixData0.searchRank < prefixData1.searchRank
    })

    for prefixData in listByRank {
      var hit = Hit(callSign: call, prefixData: prefixData)
      hit.updateHit(
        spotId: callStructure.spotId,
        sequence: callStructure.sequence
      )

      // Apply BigCTY overrides to call parser results (QRZ is authoritative)
      if let bigCTY = bigCTYData {
        hit = applyBigCTYOverrides(to: hit, using: bigCTY)
      }

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

    matches = searchMainDictionary(structure: callStructure, saveHit: false)
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

