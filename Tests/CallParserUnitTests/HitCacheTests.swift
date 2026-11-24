import Testing
@testable import CallParser

struct HitCacheTests {
    @Test func statisticsTrackHitsAndMisses() async {
        let cache = HitCache<String, String>(maxCapacity: 2)
        let initial = await cache.cacheHitMissRatio()
        #expect(initial.hits == 0 && initial.misses == 0 && initial.ratio == 0)
        await cache.updateCache("key", value: "value")
        #expect(await cache.checkCache("key") == "value")
        #expect(await cache.checkCache("missing") == nil)
        let statistics = await cache.cacheHitMissRatio()
        #expect(statistics.hits == 1 && statistics.misses == 1 && statistics.ratio == 0.5)
    }
}
