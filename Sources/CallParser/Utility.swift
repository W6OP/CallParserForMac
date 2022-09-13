//
//  File.swift
//  
//
//  Created by Peter Bourget on 9/12/22.
//

import Foundation

// MARK: - Structs

/// Call sign metadata returned to the calling application.
public struct Hit: Identifiable, Hashable {

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

  public var callSignFlags: [CallSignFlags]

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

    callSignFlags = prefixData.callSignFlags
  }
  mutating func updateHit(spotId: Int, sequence: Int) {
    self.spotId = spotId
    self.sequence = sequence
  }
}

// MARK: - Actors

/// Cache hits for future use
actor HitCache {
  var cache = [String: Hit]()

  func setReserveCapacity(amount: Int) {
    cache.reserveCapacity(amount)
  }

  /// Update the hit cache.
  /// - Parameters:
  ///   - call: String
  ///   - hit: Hit
  func updateCache(call: String, hit: Hit) {
    if cache[call] == nil {
      cache[call] = hit
    }
  }

  /// Check if the hit is already in the cache
  /// - Parameter call: call sign to lookup.
  /// - Returns: Hit
  func checkCache(call: String) -> Hit? {
     if cache[call] != nil { return cache[call] }
     return nil
   }

  func clearCache() {
    cache.removeAll()
  }
} // end actor
