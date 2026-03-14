//
//  CTYFileManager.swift
//  CallParser
//
//  Created by Peter Bourget on 3/14/26.
//

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
  case zipExtractionFailed(String)
  case csvNotFound
  case parseFailed(String)

  public var description: String {
    switch self {
    case .downloadFailed(let message): return "BigCTY download failed: \(message)"
    case .zipExtractionFailed(let message): return "BigCTY zip extraction failed: \(message)"
    case .csvNotFound: return "cty.csv not found in BigCTY archive"
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

  /// The base URL for BigCTY downloads.
  private static let bigCTYBaseURL = "https://www.country-files.com/bigcty/download"

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

  /// Downloads the BigCTY zip file, extracts `cty.csv`, saves it to
  /// Application Support, parses it, and returns a ``BigCTYData``.
  ///
  /// The extracted `cty.csv` is persisted so it can be reloaded on subsequent
  /// app launches via ``loadBigCTYFromDisk()``.
  ///
  /// - Parameter dateString: The date portion of the filename in `YYYYMMDD` format
  ///   (e.g. `"20260311"`). If `nil`, the current date is used.
  /// - Returns: A ``BigCTYData`` containing parsed entity and exact-match data.
  /// - Throws: ``BigCTYError`` if download, extraction, or parsing fails.
  public func downloadAndParseBigCTY(dateString: String? = nil) async throws -> BigCTYData {
    let dateStr = dateString ?? currentDateString()
    let year = String(dateStr.prefix(4))
    let urlString = "\(Self.bigCTYBaseURL)/\(year)/bigcty-\(dateStr).zip"

    guard let url = URL(string: urlString) else {
      throw BigCTYError.downloadFailed("Invalid URL: \(urlString)")
    }

    logger.log("Downloading BigCTY from \(urlString)")

    // Download to temp directory
    let (zipFileURL, response) = try await URLSession.shared.download(from: url)

    if let httpResponse = response as? HTTPURLResponse,
       httpResponse.statusCode != 200 {
      try? FileManager.default.removeItem(at: zipFileURL)
      throw BigCTYError.downloadFailed("HTTP \(httpResponse.statusCode)")
    }

    defer {
      try? FileManager.default.removeItem(at: zipFileURL)
    }

    // Extract cty.csv from the zip and save to Application Support
    let csvContent = try extractAndSaveCTYCSV(from: zipFileURL)

    logger.log("BigCTY downloaded and saved to Application Support")

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

  /// Deletes the stored BigCTY `cty.csv` file from Application Support.
  public func deleteBigCTYFile() throws {
    let fileURL = try bigCTYFileURL()
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
      logger.log("Deleted BigCTY file at \(fileURL.path)")
    }
  }

  /// Generates a date string in `YYYYMMDD` format for today's date.
  private func currentDateString() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd"
    return formatter.string(from: Date())
  }

  /// Extracts `cty.csv` from a zip archive and saves it to Application Support.
  /// - Parameter zipURL: The local file URL of the downloaded zip archive.
  /// - Returns: The content of the extracted `cty.csv` file.
  private func extractAndSaveCTYCSV(from zipURL: URL) throws -> String {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    defer {
      try? FileManager.default.removeItem(at: tempDir)
    }

    #if os(macOS)
    // Use /usr/bin/ditto which works in the sandbox and handles zip files
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-xk", zipURL.path, tempDir.path]

    let errorPipe = Pipe()
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
      throw BigCTYError.zipExtractionFailed(errorMessage)
    }
    #else
    throw BigCTYError.zipExtractionFailed("Zip extraction not supported on this platform")
    #endif

    // Find cty.csv in the extracted files
    let extractedCSV = tempDir.appendingPathComponent("cty.csv")
    guard FileManager.default.fileExists(atPath: extractedCSV.path) else {
      throw BigCTYError.csvNotFound
    }

    let csvContent = try String(contentsOf: extractedCSV, encoding: .utf8)

    // Save to Application Support for future loads
    let destinationURL = try bigCTYFileURL()
    try csvContent.write(to: destinationURL, atomically: true, encoding: .utf8)
    logger.log("Saved cty.csv to \(destinationURL.path)")

    return csvContent
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
      let longitude = Double(parts[7].trimmingCharacters(in: .whitespaces)) ?? 0.0
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
  /// Checks for an exact call match first, then falls back to prefix-based entity matching.
  ///
  /// - Parameters:
  ///   - hit: The `Hit` to potentially override.
  ///   - bigCTYData: The parsed BigCTY data.
  /// - Returns: An updated `Hit` with BigCTY overrides applied, or the original if no match.
  public func applyBigCTYOverrides(to hit: Hit, using bigCTYData: BigCTYData) -> Hit {
    var updatedHit = hit
    let callUpper = hit.call.uppercased()

    // Check for exact call match first
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
      return updatedHit
    }

    // Fall back to prefix matching — try longest prefix first
    let matchedRecord = findBestPrefixMatch(for: callUpper, in: bigCTYData.entities)
    if let record = matchedRecord {
      updatedHit.country = record.country
      updatedHit.dxcc_entity = record.dxcc
      updatedHit.continent = record.continent
      updatedHit.cq_zone = Set([record.cqZone])
      updatedHit.itu_zone = Set([record.ituZone])
      updatedHit.latitude = String(record.latitude)
      updatedHit.longitude = String(record.longitude)
      updatedHit.timeZone = String(record.timeZone)
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
