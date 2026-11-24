import Foundation

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

  // The single-pass scanner keeps its validation and normalization branches together.
  // swiftlint:disable cyclomatic_complexity
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
    return String(bytes: result, encoding: .utf8) ?? ""
  }

  // swiftlint:enable cyclomatic_complexity

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
      let byte = view[start]
      return byte == 0x50 || byte == 0x4D                       // P, M
    case 2:
      let firstByte = view[start]
      let secondByte = view[view.index(after: start)]
      // MM, AM, DX
      return (firstByte == 0x4D && secondByte == 0x4D)
          || (firstByte == 0x41 && secondByte == 0x4D)
          || (firstByte == 0x44 && secondByte == 0x58)
    case 3:
      var idx = start
      let firstByte = view[idx]; idx = view.index(after: idx)
      let secondByte = view[idx]; idx = view.index(after: idx)
      let thirdByte = view[idx]
      // QRP, QRO
      return firstByte == 0x51 && secondByte == 0x52 && (thirdByte == 0x50 || thirdByte == 0x4F)
    default:
      return false
    }
  }

  @inline(__always)
  private static func isAsciiDigit(_ byte: UInt8) -> Bool {
    return byte >= 0x30 && byte <= 0x39
  }
}
