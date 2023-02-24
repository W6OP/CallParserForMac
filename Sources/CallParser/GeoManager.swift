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

  init() {}

  func getCoordinate(from address: String) async throws -> CLLocationCoordinate2D {
      let geocoder = CLGeocoder()

      guard let placemarks = try await geocoder.geocodeAddressString(address)
          .compactMap( { $0.location } )
          .first(where: { $0.horizontalAccuracy >= 0 } )
      else {
          throw CLError(.geocodeFoundNoResult)
      }

    return placemarks.coordinate
  }

  // TODO: - Create cache
  // TODO: - Do something to check for rate limiting
  func forwardGeocoding(address: String) async throws -> (latitude: Double, longitude: Double) {
    let geocoder = CLGeocoder()
    var coordinates = (latitude: 0.0, longitude: 0.0)

    //let placemarks = try! await geocoder.geocodeAddressString(address)
    guard let placemarks = try await geocoder.geocodeAddressString(address)
        .compactMap( { $0.location } )
        .first(where: { $0.horizontalAccuracy >= 0 } )
    else {
        throw CLError(.geocodeFoundNoResult)
    }

//    var location: CLLocation?

//    if placemarks.count > 0 {
//      location = placemarks.first?.location
//    }
//
//    if let location = location {
      let coordinate = placemarks.coordinate
      coordinates.latitude = coordinate.latitude
      coordinates.longitude = coordinate.longitude
//    }
//    else
//    {
//      self.logger.log("No Matching Location Found")
//    }

    return coordinates
  }



} // end class
