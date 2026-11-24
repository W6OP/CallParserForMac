//
//  CallLookup.swift
//  CallParser
//
//  Created by Peter Bourget on 6/6/20.
//  Copyright © 2020 Peter Bourget. All rights reserved.
//

// import Algorithms
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
  // swiftlint:disable:next identifier_name
  public let dx: [Hit]
}

extension CallLookup {

  /// Performs two lookups for spotter and DX call signs.
  /// - Parameters:
  ///   - spotter: The spotting station call sign.
  ///   - dx: The DX station call sign.
  /// - Returns: Combined array of `Hit` results.
  @available(
    *, deprecated,
    message: "Use lookupCallPairGrouped(spotter:dx:) which returns CallPairHits with separate spotter and dx results."
  )
  // swiftlint:disable:next identifier_name
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
    // swiftlint:disable:next identifier_name
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

    // No QRZ session -- use the local parser only. Not cached: only QRZ
    // results are. A local hit is a coarse prefix/country location, and
    // caching it would keep that location for the rest of the session even
    // after a QRZ session becomes active. Local resolution is in-memory and
    // cheap, so re-resolving each time costs little.
    let hitCollection = resolveLocally(call: lookupCall)
    hits.append(contentsOf: hitCollection)
    if verboseLogging {
      logger.log("\(callSign) retrieved from call parser (not cached)")
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
