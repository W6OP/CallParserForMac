import Foundation
import os

private struct CTYAlias {
  let call: String
  let cqOverride: Int?
  let ituOverride: Int?
}

extension CallLookup {
  /// Parses the BigCTY `cty.csv` content into a ``BigCTYData`` structure.
  ///
  /// Each line has the format:
  /// `prefix,country,dxcc,continent,cq_zone,itu_zone,lat,lon,timezone,aliases;`
  ///
  /// Aliases are space-separated. Prefixed with `=` means exact call match.
  /// Zone overrides use `(cq)` and `[itu]` notation.
  func parseBigCTYCSV(_ csv: String) throws -> BigCTYData {
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

      if parts.count > 9 {
        parseAliases(parts[9], for: record, entities: &entities, exactMatches: &exactMatches)
      }
    }

    logger.log("Parsed \(entities.count) entities and \(exactMatches.count) exact matches from BigCTY")
    return BigCTYData(entities: entities, exactMatches: exactMatches)
  }

  private func parseAliases(
    _ field: String,
    for record: CTYRecord,
    entities: inout [String: CTYRecord],
    exactMatches: inout [String: CTYExactMatch]
  ) {
    let aliasField = field.trimmingCharacters(in: .whitespaces)
    for entry in aliasField.split(separator: " ") {
      let alias = parseAlias(String(entry))
      if alias.call.hasPrefix("=") {
        let exactCall = String(alias.call.dropFirst()).uppercased()
        exactMatches[exactCall] = CTYExactMatch(
          callSign: exactCall,
          entity: record,
          cqZoneOverride: alias.cqOverride,
          ituZoneOverride: alias.ituOverride
        )
      } else {
        let prefixKey = alias.call.uppercased()
        if entities[prefixKey] == nil {
          entities[prefixKey] = CTYRecord(
            prefix: prefixKey,
            country: record.country,
            dxcc: record.dxcc,
            continent: record.continent,
            cqZone: alias.cqOverride ?? record.cqZone,
            ituZone: alias.ituOverride ?? record.ituZone,
            latitude: record.latitude,
            longitude: record.longitude,
            timeZone: record.timeZone
          )
        }
      }
    }
  }

  /// Parses a single alias entry, extracting the call/prefix and any zone overrides.
  ///
  /// Format examples:
  /// - `3B7` — plain prefix alias
  /// - `=9M4SDX` — exact call match
  /// - `B0(23)[42]` — prefix with CQ zone 23 and ITU zone 42 overrides
  /// - `=7O2A(37)[48]` — exact match with zone overrides
  private func parseAlias(_ alias: String) -> CTYAlias {
    var remaining = alias
    var cqOverride: Int?
    var ituOverride: Int?

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

    return CTYAlias(call: remaining, cqOverride: cqOverride, ituOverride: ituOverride)
  }

}
