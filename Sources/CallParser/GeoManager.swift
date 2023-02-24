//
//  File.swift
//  
//
//  Created by Peter Bourget on 2/23/23.
//

import Foundation
import CoreLocation
import os

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

    if addressCache[address] != nil {
      return addressCache[address] ?? coordinates
    }

    guard let location = try await geocoder.geocodeAddressString(address)
      .compactMap( { $0.location } )
      .first(where: { $0.horizontalAccuracy >= 0 } )
    else {
      throw CLError(.geocodeFoundNoResult)
    }

    let coordinate = location.coordinate
    coordinates.latitude = coordinate.latitude
    coordinates.longitude = coordinate.longitude

    addressCache[address] = coordinates

    return coordinates
  }
} // end class
