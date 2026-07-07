//
//  CTYFileManager.swift
//  CallParser
//
//  Created by Peter Bourget on 3/14/26.
//

import Foundation
import os

/*
 Storage: cty​.csv is saved to Application ​Support​/​Call​Parser​/cty​.csv (works in both macOS and iOS sandboxes).

 Public API:

 • download​And​Parse​Big​CTY() — Downloads cty.csv directly, saves to Application Support, returns parsed Big​CTYData
 • load​Big​CTYFrom​Disk() — Loads and parses the previously saved cty​.csv on app startup. Returns nil if no file exists
 • has​Big​CTYFile() — Quick check whether a saved file exists
 • big​CTYFile​URL() — Returns the storage path
 • apply​Big​CTYOverrides(to​:using:) — Applies BigCTY data to override a Hit from the call parser

 Flow:
 1. On init, Call​Lookup automatically loads cty​.csv from Application Support if it exists
 2. When the app triggers a download, download​And​Parse​Big​CTY() fetches cty.csv directly, saves it, and returns the parsed data — the caller should also set call​Lookup​.big​CTYData with the result
 3. On subsequent launches, the saved cty​.csv is loaded automatically
 */

// MARK: - BigCTY Download and Parsing

/// Represents a single DXCC entity record parsed from the BigCTY `cty.csv` file.
public struct CTYRecord: Sendable {
  public let prefix: String
  public let country: String
  public let dxcc: Int
  public let continent: String
  public let cqZone: Int
  public let ituZone: Int
  public let latitude: Double
  public let longitude: Double
  public let timeZone: Double
}

/// Errors that can occur during BigCTY download and parsing.
public enum BigCTYError: Error, CustomStringConvertible {
  case downloadFailed(String)
  case parseFailed(String)

  public var description: String {
    switch self {
    case .downloadFailed(let message): return "BigCTY download failed: \(message)"
    case .parseFailed(let message): return "BigCTY parse failed: \(message)"
    }
  }
}

/// Holds the parsed BigCTY data with both prefix-based and exact call sign lookups.
public struct BigCTYData: Sendable {
  /// Entity records keyed by DXCC prefix (e.g. "BY", "3D2/r", "W").
  public let entities: [String: CTYRecord]

  /// Exact call sign overrides. Key is the uppercased call sign,
  /// value includes optional CQ and ITU zone overrides.
  public let exactMatches: [String: CTYExactMatch]
}

/// An exact call sign match from BigCTY, with optional zone overrides.
public struct CTYExactMatch: Sendable {
  public let callSign: String
  /// The parent entity record this call belongs to.
  public let entity: CTYRecord
  /// CQ zone override, if different from the entity default.
  public let cqZoneOverride: Int?
  /// ITU zone override, if different from the entity default.
  public let ituZoneOverride: Int?
}

extension CallLookup {

  /// The direct URL for the BigCTY CSV file.
  private static let bigCTYDownloadURL = "https://www.country-files.com/cty/cty.csv"

  /// The subdirectory name used within Application Support for storing BigCTY files.
  private static let bigCTYDirectoryName = "CallParser"

  /// The filename used for the stored BigCTY CSV file.
  private static let bigCTYFileName = "cty.csv"

  /// Returns the Application Support directory for storing BigCTY files,
  /// creating it if necessary.
  ///
  /// On macOS: `~/Library/Application Support/CallParser/`
  /// On iOS: `<sandbox>/Library/Application Support/CallParser/`
  private func bigCTYStorageDirectory() throws -> URL {
    let appSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = appSupport.appendingPathComponent(Self.bigCTYDirectoryName)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  /// Returns the file URL where the BigCTY `cty.csv` is stored on disk.
  public func bigCTYFileURL() throws -> URL {
    return try bigCTYStorageDirectory()
      .appendingPathComponent(Self.bigCTYFileName)
  }

  /// Downloads `cty.csv` directly from country-files.com, saves it to
  /// Application Support, parses it, and returns a ``BigCTYData``.
  ///
  /// The downloaded `cty.csv` is persisted so it can be reloaded on subsequent
  /// app launches via ``loadBigCTYFromDisk()``.
  ///
  /// - Returns: A ``BigCTYData`` containing parsed entity and exact-match data.
  /// - Throws: ``BigCTYError`` if download or parsing fails.
  public func downloadAndParseBigCTY() async throws -> BigCTYData {
    guard let url = URL(string: Self.bigCTYDownloadURL) else {
      throw BigCTYError.downloadFailed("Invalid URL: \(Self.bigCTYDownloadURL)")
    }

    logger.log("Downloading BigCTY from \(Self.bigCTYDownloadURL)")

    let (data, response) = try await URLSession.shared.data(from: url)

    if let httpResponse = response as? HTTPURLResponse,
       httpResponse.statusCode != 200 {
      throw BigCTYError.downloadFailed("HTTP \(httpResponse.statusCode)")
    }

    guard let csvContent = String(data: data, encoding: .utf8) else {
      throw BigCTYError.downloadFailed("Unable to decode response as UTF-8")
    }

    // Save to Application Support for future loads
    let destinationURL = try bigCTYFileURL()
    try csvContent.write(to: destinationURL, atomically: true, encoding: .utf8)
    logger.log("Saved cty.csv to \(destinationURL.path)")

    // Parse the CSV content
    return try parseBigCTYCSV(csvContent)
  }

  /// Loads and parses the previously downloaded `cty.csv` from Application Support.
  ///
  /// Call this on app launch to restore BigCTY data without a network request.
  ///
  /// - Returns: A ``BigCTYData`` if a saved file exists, or `nil` if no file is found.
  /// - Throws: ``BigCTYError`` if the file exists but cannot be parsed.
  public func loadBigCTYFromDisk() throws -> BigCTYData? {
    let fileURL: URL
    do {
      fileURL = try bigCTYFileURL()
    } catch {
      return nil
    }

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }

    let csvContent = try String(contentsOf: fileURL, encoding: .utf8)
    logger.log("Loaded BigCTY from \(fileURL.path)")
    return try parseBigCTYCSV(csvContent)
  }

  /// Returns `true` if a BigCTY `cty.csv` file has been previously downloaded.
  public func hasBigCTYFile() -> Bool {
    guard let fileURL = try? bigCTYFileURL() else { return false }
    return FileManager.default.fileExists(atPath: fileURL.path)
  }

  /// Parses the BigCTY `cty.csv` content into a ``BigCTYData`` structure.
  ///
  /// Each line has the format:
  /// `prefix,country,dxcc,continent,cq_zone,itu_zone,lat,lon,timezone,aliases;`
  ///
  /// Aliases are space-separated. Prefixed with `=` means exact call match.
  /// Zone overrides use `(cq)` and `[itu]` notation.
  private func parseBigCTYCSV(_ csv: String) throws -> BigCTYData {
    var entities = [String: CTYRecord]()
    var exactMatches = [String: CTYExactMatch]()

    let lines = csv.components(separatedBy: .newlines)

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }

      // Remove trailing semicolon
      let cleanLine = trimmed.hasSuffix(";")
        ? String(trimmed.dropLast())
        : trimmed

      // Split into fields by comma, but only the first 9 commas are field delimiters.
      // The 10th field (aliases) may contain commas within call signs, but they are
      // actually space-separated within that field.
      let parts = cleanLine.split(separator: ",", maxSplits: 9).map { String($0) }
      guard parts.count >= 9 else { continue }

      let entityPrefix = parts[0].trimmingCharacters(in: .whitespaces)
      let country = parts[1].trimmingCharacters(in: .whitespaces)
      let dxcc = Int(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0
      let continent = parts[3].trimmingCharacters(in: .whitespaces)
      let cqZone = Int(parts[4].trimmingCharacters(in: .whitespaces)) ?? 0
      let ituZone = Int(parts[5].trimmingCharacters(in: .whitespaces)) ?? 0
      let latitude = Double(parts[6].trimmingCharacters(in: .whitespaces)) ?? 0.0
      // AD1C's cty.csv stores longitude as degrees WEST-positive (e.g. the USA
      // is +98). The rest of CallParser (and PrefixList.xml) uses the standard
      // East-positive / West-negative convention, so negate here at the import
      // boundary. Without this, BigCTY-refined US hits plot in central Asia.
      let longitude = -(Double(parts[7].trimmingCharacters(in: .whitespaces)) ?? 0.0)
      let timeZone = Double(parts[8].trimmingCharacters(in: .whitespaces)) ?? 0.0

      let record = CTYRecord(
        prefix: entityPrefix,
        country: country,
        dxcc: dxcc,
        continent: continent,
        cqZone: cqZone,
        ituZone: ituZone,
        latitude: latitude,
        longitude: longitude,
        timeZone: timeZone
      )

      entities[entityPrefix.uppercased()] = record

      // Parse aliases if present (field index 9)
      if parts.count > 9 {
        let aliasField = parts[9].trimmingCharacters(in: .whitespaces)
        let aliases = aliasField.split(separator: " ").map { String($0) }

        for alias in aliases {
          let (call, cqOverride, ituOverride) = parseAlias(alias)

          if call.hasPrefix("=") {
            // Exact call sign match
            let exactCall = String(call.dropFirst()).uppercased()
            exactMatches[exactCall] = CTYExactMatch(
              callSign: exactCall,
              entity: record,
              cqZoneOverride: cqOverride,
              ituZoneOverride: ituOverride
            )
          } else {
            // Prefix alias — store as entity with same record
            let prefixKey = call.uppercased()
            if entities[prefixKey] == nil {
              let aliasRecord = CTYRecord(
                prefix: prefixKey,
                country: country,
                dxcc: dxcc,
                continent: continent,
                cqZone: cqOverride ?? cqZone,
                ituZone: ituOverride ?? ituZone,
                latitude: latitude,
                longitude: longitude,
                timeZone: timeZone
              )
              entities[prefixKey] = aliasRecord
            }
          }
        }
      }
    }

    logger.log("Parsed \(entities.count) entities and \(exactMatches.count) exact matches from BigCTY")
    return BigCTYData(entities: entities, exactMatches: exactMatches)
  }

  /// Parses a single alias entry, extracting the call/prefix and any zone overrides.
  ///
  /// Format examples:
  /// - `3B7` — plain prefix alias
  /// - `=9M4SDX` — exact call match
  /// - `B0(23)[42]` — prefix with CQ zone 23 and ITU zone 42 overrides
  /// - `=7O2A(37)[48]` — exact match with zone overrides
  private func parseAlias(_ alias: String) -> (call: String, cqOverride: Int?, ituOverride: Int?) {
    var remaining = alias
    var cqOverride: Int? = nil
    var ituOverride: Int? = nil

    // Extract ITU zone override [nn]
    if let openBracket = remaining.lastIndex(of: "["),
       let closeBracket = remaining.lastIndex(of: "]"),
       openBracket < closeBracket {
      let ituStr = remaining[remaining.index(after: openBracket)..<closeBracket]
      ituOverride = Int(ituStr)
      remaining = String(remaining[remaining.startIndex..<openBracket])
    }

    // Extract CQ zone override (nn)
    if let openParen = remaining.lastIndex(of: "("),
       let closeParen = remaining.lastIndex(of: ")"),
       openParen < closeParen {
      let cqStr = remaining[remaining.index(after: openParen)..<closeParen]
      cqOverride = Int(cqStr)
      remaining = String(remaining[remaining.startIndex..<openParen])
    }

    return (remaining, cqOverride, ituOverride)
  }

  /// Applies BigCTY data to override fields on a `Hit` that came from the local call parser.
  ///
  /// Checks for an exact call match first (authoritative single-call mapping),
  /// then falls back to prefix-based matching. The prefix-match path only
  /// refines fields when BigCTY agrees with the parser's DXCC entity —
  /// otherwise multi-hit results (e.g. TX4YKP's seven possible French
  /// overseas territories, or VK9/W6OP's several VK9 sub-entities) would
  /// all collapse onto whichever single BigCTY prefix record matches the
  /// call sign.
  ///
  /// - Parameters:
  ///   - hit: The `Hit` to potentially override.
  ///   - bigCTYData: The parsed BigCTY data.
  /// - Returns: An updated `Hit` with BigCTY overrides applied, or the original if no match.
  public func applyBigCTYOverrides(to hit: Hit, using bigCTYData: BigCTYData) -> Hit {
    var updatedHit = hit
    let callUpper = hit.call.uppercased()

    // Exact call match -- BigCTY is authoritative for this specific call.
    if let exactMatch = bigCTYData.exactMatches[callUpper] {
      let entity = exactMatch.entity
      updatedHit.country = entity.country
      updatedHit.dxcc_entity = entity.dxcc
      updatedHit.continent = entity.continent
      updatedHit.cq_zone = Set([exactMatch.cqZoneOverride ?? entity.cqZone])
      updatedHit.itu_zone = Set([exactMatch.ituZoneOverride ?? entity.ituZone])
      updatedHit.latitude = String(entity.latitude)
      updatedHit.longitude = String(entity.longitude)
      updatedHit.timeZone = String(entity.timeZone)
      if verboseLogging {
        logger.log("\(hit.call) retrieved from cty.dat")
      }
      return updatedHit
    }

    // Fall back to longest-prefix match, but only refine when BigCTY agrees
    // with the parser's DXCC entity. This preserves the multiple distinct
    // entity hits the parser produces for ambiguous portable calls.
    if let record = findBestPrefixMatch(for: callUpper, in: bigCTYData.entities),
       record.dxcc == hit.dxcc_entity {
      updatedHit.country = record.country
      updatedHit.continent = record.continent
      updatedHit.cq_zone = Set([record.cqZone])
      updatedHit.itu_zone = Set([record.ituZone])
      updatedHit.latitude = String(record.latitude)
      updatedHit.longitude = String(record.longitude)
      updatedHit.timeZone = String(record.timeZone)
      if verboseLogging {
        logger.log("\(hit.call) refined from cty.dat prefix")
      }
    }

    return updatedHit
  }

  /// Finds the longest matching prefix for a call sign in the entity dictionary.
  private func findBestPrefixMatch(for call: String, in entities: [String: CTYRecord]) -> CTYRecord? {
    // Try progressively shorter prefixes
    var prefix = call
    while !prefix.isEmpty {
      if let record = entities[prefix] {
        return record
      }
      prefix = String(prefix.dropLast())
    }
    return nil
  }
}
