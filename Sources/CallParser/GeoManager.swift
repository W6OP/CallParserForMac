//
//  GeoManager.swift
//  CallParser
//

import Foundation
import CoreLocation

/// Serializes requests across manager instances. Waiting remains cancellation-aware.
actor GeocodeRequestGate {
    private var isBusy = false

    func acquire() async throws {
        while isBusy {
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        isBusy = true
    }

    func release() {
        isBusy = false
    }
}

final class GeoManager: Sendable {
    typealias Coordinates = (latitude: Double, longitude: Double)
    typealias Geocode = @Sendable (String) async throws -> Coordinates?

    private static let sharedGate = GeocodeRequestGate()
    private let gate: GeocodeRequestGate
    private let geocode: Geocode
    private let addressCache = AddressCache()

    init(gate: GeocodeRequestGate = GeoManager.sharedGate, geocode: @escaping Geocode = GeoManager.lookup) {
        self.gate = gate
        self.geocode = geocode
    }

    private static func lookup(_ address: String) async throws -> Coordinates? {
        do {
            let locations = try await CLGeocoder().geocodeAddressString(address)
            guard let location = locations.compactMap(\.location).first(where: { $0.horizontalAccuracy >= 0 }) else {
                return nil
            }
            return (location.coordinate.latitude, location.coordinate.longitude)
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            return nil
        }
    }

    /// Returns cached coordinates or requests them serially from the geocoder.
    func getCoordinatesFromAddress(address: String) async throws -> Coordinates {
        try Task.checkCancellation()
        if let cached = await addressCache.checkCache(address: address) {
            try Task.checkCancellation()
            return cached
        }

        try await gate.acquire()
        do {
            // Another caller may have populated the cache while this one waited.
            if let cached = await addressCache.checkCache(address: address) {
                try Task.checkCancellation()
                await gate.release()
                return cached
            }

            let coordinates = try await geocode(address)
            try Task.checkCancellation()
            let result = coordinates ?? (latitude: 0.0, longitude: 0.0)
            await addressCache.updateCache(address: address, coordinates: result, isNegative: coordinates == nil)
            await gate.release()
            return result
        } catch {
            await gate.release()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
