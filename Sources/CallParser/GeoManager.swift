//
//  File.swift
//  
//
//  Created by Peter Bourget on 2/23/23.
//

import Foundation
import CoreLocation
import os

final class GeoManager: Sendable {
  let logger = Logger(subsystem: "com.w6op.CallParser", category: "GeoManager")

  let addressCache = AddressCache()

  init() {}

  // TODO: - Do something to check for rate limiting

  /// Get the latitude and longitude from an address.
  /// - Parameter address: String
  /// - Returns: (String: Double, String: Double)
  func getCoordinatesFromAddress(address: String) async throws -> (latitude: Double, longitude: Double) {
    let geocoder = CLGeocoder()
    var coordinates = (latitude: 0.0, longitude: 0.0)
    var location: CLLocation

    if let cachedCoordinates = await addressCache.checkCache(address: address) {
      return cachedCoordinates
    }

    try Task.checkCancellation()

    do {
      location = try await geocoder.geocodeAddressString(address)
        .compactMap( { $0.location } )
        .first(where: { $0.horizontalAccuracy >= 0 } )!

      let coordinate = location.coordinate
      coordinates.latitude = coordinate.latitude
      coordinates.longitude = coordinate.longitude
      await addressCache.updateCache(address: address, coordinates: coordinates)
    } catch {
      // Cache the failure so we don't hammer CLGeocoder for the same
      // address again. The negative entry expires after a TTL so transient
      // failures (network blips, throttling) eventually recover.
      await addressCache.updateCache(
        address: address,
        coordinates: coordinates,
        isNegative: true
      )
      return coordinates
    }

    return coordinates
  }
} // end class

