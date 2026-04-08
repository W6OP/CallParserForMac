# CallParser Concurrency Modernization Plan

Created: 2026-04-08
Status: Implementation not started

---

## Goal
Modernize CallParser to full Swift concurrency so that:
1. `lookupCallPairGrouped` runs spotter + DX lookups in parallel
2. Batch lookups (N calls) can run via TaskGroup
3. All mutable shared state is properly isolated (no data races)
4. The pure computation path remains fast and non-blocking

---

## Architecture Overview (Before vs After)

### Before
```
CallLookup (class)
  ├── Mutable QRZ session state (vars, unprotected)
  ├── Mutable prefix dictionaries (vars, but never mutated after init)
  ├── QRZManager (class, mutable state)
  ├── DataParser (class, stateless)
  ├── GeoManager (class, actor cache inside)
  ├── HitCache (actor) ✓
  └── lookupCall() -- async but sequential
```

### After
```
CallLookup (class, Sendable)
  ├── Immutable prefix dictionaries (let)
  ├── QRZSession (NEW actor -- owns all QRZ mutable state)
  │     ├── sessionKey, haveSessionKey, sessionKeyRequestPending
  │     ├── qrzUserId, qrzPassword, previousQrzUserId
  │     ├── lastSessionKeyRequestTime
  │     └── logonToQrz(), requestQRZCallSignData(), etc.
  ├── QRZManager (struct/class, stateless network calls)
  ├── DataParser (struct, stateless)
  ├── GeoManager (unchanged)
  ├── HitCache (actor) ✓
  └── lookupCall() -- async, can run concurrently
      lookupCallPairGrouped() -- async let (parallel)
      lookupBatch() -- TaskGroup (parallel)
```

---

## Implementation Phases

### Phase 1: Make prefix dictionaries immutable ✅ LOW RISK
**Files**: CallLookup.swift
**Changes**:
- Change `var callSignPatterns` → `let callSignPatterns`
- Change `var portablePrefixes` → `let portablePrefixes`
- Change `var adifs` → `let adifs`
- Change `var dxccEntities` → `let dxccEntities`
- For dxccEntities: load in init and assign to let (currently loaded via mutating method)
- Move `loadDXCCEntitiesFile()` logic into init or use a static factory
- Same for `loadBigCTYData()`

**Why first**: Zero behavior change. Just proves these are truly immutable after init. If the compiler complains, we learn something important.

**Details**:
- `callSignPatterns`, `portablePrefixes`, `adifs` are assigned from PrefixFileParser in init -- straightforward to make `let`
- `dxccEntities` is populated by `loadDXCCEntitiesFile()` called from init -- need to refactor: either load inline in init or use a static helper that returns the dictionary
- `bigCTYData` is `public var` because it can be updated after download -- keep as var but document it

---

### Phase 2: Make DataParser a struct ✅ LOW RISK
**Files**: DataParser.swift
**Changes**:
- Change `class DataParser` → `struct DataParser`
- `parseSessionData` is currently `async` but does no async work -- remove `async`
- `parseCallSignData` is already sync -- no change
- All methods are pure functions on input data -- perfect struct candidate

**Why**: Eliminates a reference type. Makes Sendable conformance automatic.

---

### Phase 3: Create `QRZSession` actor ⚠️ MEDIUM RISK
**Files**: NEW QRZSession.swift, CallLookup.swift, QRZManager.swift
**Changes**:

Create new `actor QRZSession`:
```swift
actor QRZSession {
    private let qrzManager = QRZManager()
    private let dataParser = DataParser()
    private let geoManager = GeoManager()

    private var sessionKey: String?
    private var haveSessionKey = false
    private var sessionKeyRequestPending = false
    private var lastSessionKeyRequestTime: Date?
    private var qrzUserId = ""
    private var qrzPassword = ""
    private var previousQrzUserId = ""

    var isActive: Bool { haveSessionKey }

    func logon(userId: String, password: String) async throws -> Bool
    func lookupCall(_ call: String) async -> Hit?
    // ... session management methods move here
}
```

Move from CallLookup into QRZSession:
- `logonToQrz()`
- `requestQRZSessionKey()`
- `determineErrorType()`
- `requestQRZCallSignData()` (both overloads)
- `tryGeocodingAddress()`
- `processQRZErrorMessage()`

Simplify QRZManager:
- Remove stored `sessionKey`, `qrzUserName`, `qrzPassword`
- Make methods take parameters instead of reading instance state
- Or inline into QRZSession since it's small (124 lines)

Update CallLookup:
- Replace `var qrzManager`, `var haveSessionKey`, etc. with `let qrzSession: QRZSession?`
- `lookupCall` calls `qrzSession?.lookupCall()` instead of inline QRZ logic

---

### Phase 4: Parallel lookups via `async let` ✅ LOW RISK
**Files**: CallLookup.swift
**Changes**:

```swift
// lookupCallPairGrouped becomes:
public func lookupCallPairGrouped(spotter: String, dx: String) async -> CallPairHits {
    async let spotterHits = lookupCall(callSign: spotter)
    async let dxHits = lookupCall(callSign: dx)
    return CallPairHits(spotter: await spotterHits, dx: await dxHits)
}
```

This is safe because:
- Cache reads/writes go through HitCache actor (already isolated)
- QRZ calls go through QRZSession actor (isolated after Phase 3)
- Prefix dictionary lookups are pure reads on immutable data (after Phase 1)

---

### Phase 5: Add batch lookup via TaskGroup ✅ LOW RISK
**Files**: CallLookup.swift
**Changes**:

Add new public API:
```swift
public func lookupBatch(callSigns: [String], maxConcurrency: Int = 8) async -> [String: [Hit]] {
    await withTaskGroup(of: (String, [Hit]).self) { group in
        var results = [String: [Hit]]()
        var inFlight = 0
        var index = callSigns.startIndex

        while index < callSigns.endIndex || !group.isEmpty {
            // Launch tasks up to maxConcurrency
            while inFlight < maxConcurrency && index < callSigns.endIndex {
                let call = callSigns[index]
                group.addTask { (call, await self.lookupCall(callSign: call)) }
                inFlight += 1
                index = callSigns.index(after: index)
            }
            // Collect one result
            if let (call, hits) = await group.next() {
                results[call] = hits
                inFlight -= 1
            }
        }
        return results
    }
}
```

---

### Phase 6: Sendable conformance and cleanup ✅ LOW RISK
**Files**: Multiple
**Changes**:
- Add `Sendable` conformance to `CallLookup` (should work after Phase 1+3)
- Mark `CallLookup` as `final class` to help with Sendable
- Audit remaining `var` properties on CallLookup
- Remove deprecated `lookupCallPair` method
- Remove deprecated `requestQRZCallSignData(call:spotInformation:)`
- Remove `determinePatternToUseOld` dead code
- Clean up fire-and-forget `Task {}` cache writes in `buildHit` methods

---

### Phase 7: Update CallParserDemo2 and tests
**Files**: Model.swift, ContentView.swift, CallParserTests.swift
**Changes**:
- Update demo app to use new parallel APIs
- Add performance comparison (sequential vs parallel)
- Update unit tests for new actor-based session management
- Add concurrency-specific tests

---

## Properties Disposition Table

### CallLookup Properties
| Property | Current | After | Rationale |
|----------|---------|-------|-----------|
| hitCache | var HitCache (actor) | let HitCache | Already actor, just make let |
| qrzManager | var QRZManager | REMOVED | Absorbed into QRZSession |
| dataParser | let DataParser | let DataParser | Already let, make struct |
| geoManager | let GeoManager | Moves to QRZSession | Only used by QRZ path |
| qrzUserId | var String | Moves to QRZSession | Session state |
| qrzPassword | var String | Moves to QRZSession | Session state |
| previousQrzUserId | var String | Moves to QRZSession | Session state |
| haveSessionKey | var Bool | Moves to QRZSession | Session state |
| sessionKeyRequestPending | var Bool | Moves to QRZSession | Session state |
| lastSessionKeyRequestTime | var Date? | Moves to QRZSession | Session state |
| useCallParserOnly | public var Bool | let (set at init) | Config, shouldn't change |
| verboseLogging | public var Bool | let (or Mutex<Bool>) | Config toggle |
| callSignList | var [String] | REMOVED | Appears unused |
| adifs | var [Int: PrefixData] | let | Immutable after init |
| prefixList | var [PrefixData] | REMOVED | Appears unused |
| callSignPatterns | var [String: [PrefixData]] | let | Immutable after init |
| portablePrefixes | var [String: [PrefixData]] | let | Immutable after init |
| mergeHits | var Bool | let | Set at init, never changed |
| cacheMaxCapacity | var Int | let | Already effectively constant |
| dxccEntities | var [Int: String] | let | Loaded once at init |
| bigCTYData | public var BigCTYData? | public var (keep) | Updated after download |

---

## Risk Mitigation
- Each phase is independently testable and committable
- Phase 1 has zero behavior change (just var→let)
- Phase 2 has zero behavior change (class→struct for stateless type)
- Phase 3 is the biggest change but is well-contained
- Phases 4-5 are additive (new parallel entry points)
- The existing sequential APIs continue to work throughout

## Breaking API Changes
- `logonToQrz` will need to go through the session actor
- `useCallParserOnly` and `verboseLogging` should become init parameters
- The deprecated methods should be removed
- `lookupBatch` is new API (additive, non-breaking)

---

## Restart Instructions for Claude

If resuming this work in a new session:

1. Read this file: `/Users/pbourget/Library/Developer/Xcode/CodingAssistant/ClaudeAgentConfig/projects/-Users-pbourget-XcodeProjects-WorkSpaces/memory/callparser-concurrency-plan.md`
2. Read MEMORY.md for current status (which phase we're on)
3. Check git log for what's been committed
4. The user wants full Swift concurrency modernization of CallParser package
5. Work through the phases in order, committing after each phase
6. Update MEMORY.md status after each phase completion
