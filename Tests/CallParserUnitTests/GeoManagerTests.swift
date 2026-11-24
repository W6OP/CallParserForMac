import Testing
@testable import CallParser

private actor GeocodeProbe {
    var calls = 0
    var active = 0
    var maxActive = 0
    var failNext = false

    func lookup(_ address: String) async throws -> GeoManager.Coordinates? {
        calls += 1
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(70))
        if failNext {
            failNext = false
            throw TestError.transient
        }
        return address == "missing" ? nil : (12, 34)
    }

    func setFailure() { failNext = true }
    enum TestError: Error { case transient }
}

struct GeoManagerTests {
    @Test func concurrentRequestsShareCacheAndSerialize() async throws {
        let probe = GeocodeProbe()
        let manager = GeoManager(gate: GeocodeRequestGate(), geocode: { try await probe.lookup($0) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for address in ["same", "same", "other"] {
                group.addTask {
                    let value = try await manager.getCoordinatesFromAddress(address: address)
                    #expect(value.latitude == 12)
                }
            }
            try await group.waitForAll()
        }
        #expect(await probe.calls == 2)
        #expect(await probe.maxActive == 1)
    }

    @Test func noResultIsCachedAndTransientFailureCanRetry() async throws {
        let probe = GeocodeProbe()
        let manager = GeoManager(gate: GeocodeRequestGate(), geocode: { try await probe.lookup($0) })
        let missing = try await manager.getCoordinatesFromAddress(address: "missing")
        #expect(missing.latitude == 0 && missing.longitude == 0)
        _ = try await manager.getCoordinatesFromAddress(address: "missing")
        #expect(await probe.calls == 1)
        await probe.setFailure()
        await #expect(throws: GeocodeProbe.TestError.self) {
            try await manager.getCoordinatesFromAddress(address: "retry")
        }
        let result = try await manager.getCoordinatesFromAddress(address: "retry")
        #expect(result.latitude == 12)
        #expect(await probe.calls == 3)
    }

    @Test func waitingRequestCanBeCancelled() async throws {
        let gate = GeocodeRequestGate()
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await gate.release()
        try await gate.acquire()
        await gate.release()
    }
    @Test func cancelledActiveRequestDoesNotCacheFailure() async throws {
        let probe = GeocodeProbe()
        let manager = GeoManager(gate: GeocodeRequestGate(), geocode: { try await probe.lookup($0) })
        let request = Task { try await manager.getCoordinatesFromAddress(address: "cancelled") }
        while await probe.calls == 0 {
            await Task.yield()
        }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        let result = try await manager.getCoordinatesFromAddress(address: "cancelled")
        #expect(result.latitude == 12)
        #expect(await probe.calls == 2)
    }
}
