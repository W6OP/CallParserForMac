//
//  File.swift
//
//
//  Created by Peter Bourget on 9/12/22.
//

import Foundation

// MARK: - Structs

/// Call sign metadata returned to the calling application.
/// // - Updated for V6
public struct Hit: Identifiable, Hashable, Sendable {

  public var id = UUID()

  public var call = ""                 //call sign as input
  public var kind = PrefixKind.none    //kind
  public var country = ""              //country
  public var province = ""             //province
  public var city = ""                 //city
  public var county = ""
  public var dxcc_entity = 0           //dxcc_entity
  public var cq_zone = Set<Int>()           //cq_zone
  public var itu_zone = Set<Int>()          //itu_zone
  public var continent = ""            //continent
  public var timeZone = ""             //time_zone
  public var latitude = "0.0"          //lat
  public var longitude = "0.0"         //long
  public var wae = 0
  public var wap = ""
  public var admin1 = ""
  public var admin2 = ""
  public var startDate = ""
  public var endDate = ""
  public var isIota = false // implement
  public var comment = ""
  public var grid = ""
  public var lotw = false
  public var image = "" // future use
  // internal use
  public var sequence = 0
  public var spotId = 0
  public var rank = 1
  public var isQRZHit = false
  public var callSignFlags: [CallSignFlags]

  private(set) var expirationDate: Date = Date()

  init(callSignDictionary: [String: String]) {
    call = callSignDictionary["call"] ?? ""
    country = callSignDictionary["country"] ?? ""
    city = callSignDictionary["addr2"] ?? ""
    county = callSignDictionary["county"] ?? ""
    province = callSignDictionary["state"] ?? ""
    latitude = callSignDictionary["lat"] ?? ""
    longitude = callSignDictionary["lon"] ?? ""
    grid = callSignDictionary["grid"] ?? ""
    lotw  = Bool(callSignDictionary["lotw"] ?? "0") ?? false
    let dxcc = callSignDictionary["dxcc"] ?? "0"
    dxcc_entity = Int(dxcc) ?? 0
    isQRZHit = true
    kind = PrefixKind.dXCC
    callSignFlags = [CallSignFlags]()
  }

  init(callSign: String, prefixData: PrefixData) {
    call = callSign
    kind = prefixData.kind
    country = prefixData.country
    province = prefixData.province
    city = prefixData.city
    dxcc_entity = prefixData.dxcc_entity
    cq_zone = prefixData.cq_zone
    itu_zone = prefixData.itu_zone
    continent = prefixData.continent
    timeZone = prefixData.timeZone
    latitude = prefixData.latitude
    longitude = prefixData.longitude
    wae = prefixData.wae
    wap = prefixData.wap
    admin1 = prefixData.admin1
    admin2 = prefixData.admin2
    startDate = prefixData.startDate
    endDate = prefixData.endDate
    isIota = prefixData.isIota
    comment = prefixData.comment
    rank = prefixData.searchRank
    callSignFlags = prefixData.callSignFlags
  }

  mutating func updateHit(spotId: Int, sequence: Int) {
    self.spotId = spotId
    self.sequence = sequence
    expirationDate = Date()
  }
}

// MARK: - Actors

// something to think about
// https://www.swiftbysundell.com/articles/caching-in-swift/

/// Cache hits for future use.
/// // - Updated for V6
//actor HitCacheOld: Sendable {
//  var cache = [String: Hit]()
//  let maxCapacity = 10000
//
//  /// Update the hit cache.
//  /// - Parameters:
//  ///   - call: String
//  ///   - hit: Hit
//  func updateCache(call: String, hit: Hit) {
//    if cache.count > 10000 {
//      // TODO: - should just remove the oldest - fix after swift 6 conversion
//      removeAll()
//    }
//
//    if cache[call] == nil {
//      cache[call] = hit
//    }
//  }
//
//  /// Check if the hit is already in the cache
//  /// - Parameter call: call sign to lookup.
//  /// - Returns: Hit
//  func checkCache(call: String) -> Hit? {
//     if cache[call] != nil { return cache[call] }
//     return nil
//   }
//
//  /// Clear the cache.
//  func removeAll() {
//    cache.removeAll()
//  }
//} // end actor

actor HitCache<Key: Hashable, Value> {
    private struct CacheEntry {
        let value: Value
        let timestamp: Date  // or any LRU metric
    }

    private var cache = [Key: CacheEntry]()
    private let maxCapacity: Int
    private var hitCount = 0
    private var missCount = 0

  var count: Int {
      return cache.count
  }

    init(maxCapacity: Int) {
        self.maxCapacity = maxCapacity
    }

    func checkCache(_ key: Key) -> Value? {
        if let entry = cache[key] {
            hitCount += 1
            // Optionally update the timestamp to mark usage
            cache[key] = CacheEntry(value: entry.value, timestamp: Date())
            return entry.value
        } else {
            missCount += 1
            return nil
        }
    }

  func updateCache(_ key: Key, value: Value) {
      cache[key] = CacheEntry(value: value, timestamp: Date())
      while cache.count > maxCapacity {
          evictLeastRecentlyUsed()
      }
  }

    /// Clears all items from the cache.
    func clearCache() {
        cache.removeAll()
    }

    func cacheHitMissRatio() -> (hits: Int, misses: Int, ratio: Double) {
        let total = hitCount + missCount
        let ratio = total > 0 ? Double(hitCount) / Double(total) : 0.0
        return (hits: hitCount, misses: missCount, ratio: ratio)
    }

    private func evictLeastRecentlyUsed() {
        if let oldestKey = cache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
            cache.removeValue(forKey: oldestKey)
        }
    }
} // end actor



actor AddressCache {
  var cache = [String: (latitude: Double, longitude: Double)]()
  let maxCapacity = 10000

  /// Update the hit cache.
  /// - Parameters:
  ///   - call: String
  ///   - hit: Hit
  func updateCache(address: String, coordinates: (latitude: Double, longitude: Double)) {
    if cache.count > 10000 {
      removeAll()
    }

    if cache[address] == nil {
      cache[address] = coordinates
    }
  }

  /// Check if the hit is already in the cache
  /// - Parameter call: call sign to lookup.
  /// - Returns: Hit
  func checkCache(address: String) -> (latitude: Double, longitude: Double)? {
     if cache[address] != nil { return cache[address] }
     return nil
   }

  /// Clear the cache.
  func removeAll() {
    cache.removeAll()
  }
} // end actor
