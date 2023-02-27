//
//  File.swift
//  
//
//  Created by Peter Bourget on 2/23/23.
//

import Foundation
import CoreLocation
import os

extension Task where Success == Never, Failure == Never {
    static func sleep(seconds: Double) async throws {
        let duration = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: duration)
    }
}

class GeoManager {
  let logger = Logger(subsystem: "com.w6op.CallParser", category: "GeoManager")

  var addressCache: [String: (latitude: Double, longitude: Double)] = [:]

  init() {}

  // TODO: - Do something to check for rate limiting

  /// Get the latitude and longitude from an address.
  /// - Parameter address: String
  /// - Returns: (String: Double, String: Double)
  func forwardGeocoding(address: String) async throws -> (latitude: Double, longitude: Double) {
    let geocoder = CLGeocoder()
    var coordinates = (latitude: 0.0, longitude: 0.0)
    var location: CLLocation

    if addressCache[address] != nil {
      return addressCache[address] ?? coordinates
    }

    // prevent throttling when large numbers of requests are mad
    do {
      try await Task.sleep(seconds: 0.25)
    } catch {
      return coordinates
    }

    do {
      location = try await geocoder.geocodeAddressString(address)
        .compactMap( { $0.location } )
        .first(where: { $0.horizontalAccuracy >= 0 } )!

      let coordinate = location.coordinate
      coordinates.latitude = coordinate.latitude
      coordinates.longitude = coordinate.longitude
      addressCache[address] = coordinates
    } catch {
      //print("the error is: \(error.localizedDescription)")
      return coordinates
    }

    return coordinates
  }
} // end class

/*
 2023-02-27 08:21:54.283021-0800 xCluster[76560:7869636] [GEOXPC] Throttled "PlaceRequest.REQUEST_TYPE_GEOCODING" request: Tried to make more than 50 requests in 60 seconds, will reset in 53 seconds - Error Domain=GEOErrorDomain Code=-3 "(null)" UserInfo={details=(
         {
         intervalType = short;
         maxRequests = 50;
         "throttler.keyPath" = "app:4JA44QU5MA.com.w6op.xcluster-2/0x20302/short(default/any)";
         timeUntilReset = 53;
         windowSize = 60;
     }
 ), requestKindString=PlaceRequest.REQUEST_TYPE_GEOCODING, timeUntilReset=53, requestKind=770}
 */
