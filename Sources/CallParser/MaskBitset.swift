//
//  MaskBitset.swift
//  CallParser
//
//  Prototype bitset-based mask matcher. Built alongside the existing
//  shape-pattern dictionary so the two paths can be A/B benchmarked.
//
//  Bit layout for one position:
//    bits  0..25  = letters A..Z
//    bits 26..35  = digits 0..9
//    bit  36      = portable indicator '/'
//    bit  37      = stop indicator '.'
//

import Foundation

// MARK: - Symbol encoding

/// Maps a callsign character into a 0..<38 bit index used by ``MaskBitset``.
public enum CallSymbol {
  @usableFromInline static let letterBase: UInt8 = 0
  @usableFromInline static let digitBase:  UInt8 = 26
  @usableFromInline static let portable:   UInt8 = 36
  @usableFromInline static let stop:       UInt8 = 37

  /// Bitset of every letter A..Z.
  public static let anyLetter:       UInt64 = ((UInt64(1) << 26) - 1)
  /// Bitset of every digit 0..9.
  public static let anyDigit:        UInt64 = ((UInt64(1) << 10) - 1) << 26
  /// Bitset of every letter or digit.
  public static let anyAlphanumeric: UInt64 = anyLetter | anyDigit
  /// Single-bit set for the portable `/` indicator.
  public static let portableBit:     UInt64 = UInt64(1) << 36
  /// Single-bit set for the `.` stop indicator.
  public static let stopBit:         UInt64 = UInt64(1) << 37

  /// Bit index for a callsign character, or `nil` if the character is not
  /// part of the supported alphabet. Lowercase letters fold to uppercase.
  @inlinable
  public static func bit(for ch: Character) -> UInt8? {
    guard let s = ch.asciiValue else { return nil }
    switch s {
    case 0x41...0x5A: return letterBase + (s - 0x41)   // A..Z
    case 0x61...0x7A: return letterBase + (s - 0x61)   // a..z folded
    case 0x30...0x39: return digitBase  + (s - 0x30)   // 0..9
    case 0x2F:        return portable                  // /
    case 0x2E:        return stop                      // .
    default:          return nil
    }
  }
}

// MARK: - MaskBitset

/// A callsign mask compiled into one `UInt64` bitset per character position.
///
/// Matching is a fixed number of `AND` operations — no string scanning, no
/// range expansion, no per-character class dispatch.
public struct MaskBitset: Sendable, Hashable {
  public let positions: [UInt64]
  /// Hoisted copy of `positions[0]` for fast bucket lookup. Zero for empty masks.
  public let firstCharSet: UInt64
  /// `true` if the final position is the portable `/` indicator.
  public let endsWithPortable: Bool

  /// Test whether a callsign (expressed as one single-bit value per
  /// character) matches this mask. Length must match exactly.
  @inlinable
  public func matches(_ callBits: [UInt64]) -> Bool {
    matches(callBits[...])
  }

  /// ArraySlice overload — lets callers reuse a single bit buffer across
  /// multiple length-varying lookups without re-encoding the input.
  @inlinable
  public func matches(_ callBits: ArraySlice<UInt64>) -> Bool {
    guard callBits.count == positions.count else { return false }
    var pi = 0
    for c in callBits {
      if positions[pi] & c == 0 { return false }
      pi &+= 1
    }
    return true
  }
}

extension MaskBitset {

  /// Compile a mask string from PrefixList.xml into a ``MaskBitset``.
  ///
  /// Supported syntax:
  /// - literal characters: `A`, `7`, etc.
  /// - meta-chars: `@` (any letter), `#` (any digit), `?` (any alphanumeric)
  /// - groups: `[ABC]`, `[A-G]`, `[#A-LRTYZ]`
  /// - indicators: `/` (portable), `.` (stop)
  ///
  /// Returns `nil` if the mask contains an unrecognised construct.
  public static func compile(_ mask: String) -> MaskBitset? {
    let trimmed = mask.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var positions: [UInt64] = []
    var endsWithPortable = false
    let chars = Array(trimmed)
    var i = 0

    while i < chars.count {
      switch chars[i] {
      case "[":
        // Find matching ']' — slice indices share the parent's index space.
        guard let close = chars[(i + 1)...].firstIndex(of: "]") else { return nil }
        var bits: UInt64 = 0
        var prev: Character? = nil
        var j = i + 1
        while j < close {
          let c = chars[j]
          if c == "-", let p = prev, j + 1 < close {
            bits |= rangeBits(from: p, to: chars[j + 1])
            prev = chars[j + 1]
            j += 2
          } else {
            bits |= literalBits(c)
            prev = c
            j += 1
          }
        }
        positions.append(bits)
        i = close + 1

      case "@": positions.append(CallSymbol.anyLetter);        i += 1
      case "#": positions.append(CallSymbol.anyDigit);         i += 1
      case "?": positions.append(CallSymbol.anyAlphanumeric);  i += 1
      case "/":
        positions.append(CallSymbol.portableBit)
        endsWithPortable = true
        i += 1
      case ".": positions.append(CallSymbol.stopBit);          i += 1
      default:  positions.append(literalBits(chars[i]));       i += 1
      }
    }

    return MaskBitset(
      positions: positions,
      firstCharSet: positions.first ?? 0,
      endsWithPortable: endsWithPortable
    )
  }

  /// Bitset for a single literal character (handles meta-chars inside groups).
  private static func literalBits(_ ch: Character) -> UInt64 {
    switch ch {
    case "@": return CallSymbol.anyLetter
    case "#": return CallSymbol.anyDigit
    case "?": return CallSymbol.anyAlphanumeric
    case "/": return CallSymbol.portableBit
    case ".": return CallSymbol.stopBit
    default:
      guard let b = CallSymbol.bit(for: ch) else { return 0 }
      return UInt64(1) << UInt64(b)
    }
  }

  /// Bitset for a character range. Ports the quirky semantics in
  /// ``PrefixFileParser/expandRange`` so behaviour matches the legacy path:
  ///
  /// - alpha→alpha and digit→digit: standard inclusive range
  /// - digit→alpha (`[0-C]`): letters strictly before `C`
  /// - alpha→digit (`[W-3]`): letters from after `W` up to (but excluding) `Z`
  private static func rangeBits(from a: Character, to b: Character) -> UInt64 {
    let aDigit = a.isASCII && a.isNumber
    let aAlpha = a.isASCII && a.isLetter
    let bDigit = b.isASCII && b.isNumber
    let bAlpha = b.isASCII && b.isLetter

    if (aAlpha && bAlpha) || (aDigit && bDigit) {
      guard let aBit = CallSymbol.bit(for: a),
            let bBit = CallSymbol.bit(for: b) else { return 0 }
      let (lo, hi) = aBit <= bBit ? (aBit, bBit) : (bBit, aBit)
      let count = UInt64(hi - lo + 1)
      let mask = count >= 64 ? UInt64.max : ((UInt64(1) << count) - 1)
      return mask << UInt64(lo)
    }

    if aDigit && bAlpha {
      guard let scalar = b.asciiValue else { return 0 }
      let endIdx = Int(scalar) - 0x41   // index of b in A..Z
      guard endIdx > 0 else { return 0 }
      return (UInt64(1) << UInt64(endIdx)) - 1
    }

    if aAlpha && bDigit {
      guard let scalar = a.asciiValue else { return 0 }
      let startIdx = Int(scalar) - 0x41 + 1   // position after a
      let endIdx = 25
      guard startIdx < endIdx else { return 0 }
      let count = UInt64(endIdx - startIdx)
      return ((UInt64(1) << count) - 1) << UInt64(startIdx)
    }

    return 0
  }
}

// MARK: - BitsetMaskIndex

/// Mask index keyed by `(maskLength, firstCharBitIndex)`.
///
/// A mask whose first position accepts multiple characters (e.g. `[AKNW]L`)
/// gets registered under every matching first-character bucket, so each
/// lookup only tests masks that could possibly start with the call's first
/// character.
public struct BitsetMaskIndex: Sendable {
  public typealias Entry = (mask: MaskBitset, data: PrefixData)

  private var buckets: [Int: [Entry]] = [:]

  public init() {}

  public mutating func insert(_ mask: MaskBitset, data: PrefixData) {
    var bits = mask.firstCharSet
    while bits != 0 {
      let firstBit = bits.trailingZeroBitCount
      let key = (mask.positions.count << 8) | firstBit
      buckets[key, default: []].append((mask, data))
      bits &= bits &- 1   // clear lowest set bit
    }
  }

  /// Return every ``PrefixData`` whose mask accepts the given callsign bits.
  /// `callBits` must contain one single-bit value per character of the call.
  public func candidates(for callBits: [UInt64]) -> [PrefixData] {
    candidates(for: callBits[...])
  }

  /// ArraySlice overload. Lets callers encode a callsign into bits once and
  /// then probe at multiple lengths (e.g. for progressive shrinking) without
  /// reallocating the bit buffer.
  public func candidates(for callBits: ArraySlice<UInt64>) -> [PrefixData] {
    guard let first = callBits.first, first != 0 else { return [] }
    let key = (callBits.count << 8) | first.trailingZeroBitCount
    guard let bucket = buckets[key] else { return [] }
    var hits: [PrefixData] = []
    hits.reserveCapacity(4)
    for entry in bucket where entry.mask.matches(callBits) {
      hits.append(entry.data)
    }
    return hits
  }

  /// Total number of stored entries across all buckets. A single mask may
  /// be present under multiple first-character buckets.
  public var entryCount: Int { buckets.values.reduce(0) { $0 + $1.count } }

  /// Number of distinct `(length, firstChar)` buckets.
  public var bucketCount: Int { buckets.count }
}

// MARK: - Callsign → bit array

extension String {
  /// Convert a callsign string into per-position single-bit values for
  /// ``MaskBitset/matches(_:)``. Returns `nil` if the call contains any
  /// character outside the supported alphabet (A–Z, 0–9, `/`, `.`).
  public func toCallBits() -> [UInt64]? {
    var bits: [UInt64] = []
    bits.reserveCapacity(count)
    for ch in self {
      guard let b = CallSymbol.bit(for: ch) else { return nil }
      bits.append(UInt64(1) << UInt64(b))
    }
    return bits
  }
}
