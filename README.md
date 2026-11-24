# CallParser

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://en.wikipedia.org/wiki/MIT_License)

CallParser is a Swift package for looking up amateur radio call signs. It uses bundled prefix data and can optionally consult QRZ.com and BigCTY data.

## Requirements

The package manifest requires Swift 6.2 or later, macOS 15 or later, or iOS 16 or later. The CallParserDemo2 project currently targets macOS 26 and uses a local copy of this package.

## Setup

Add the `CallParser` library product to your Swift package or Xcode project. For local development with CallParserDemo2, the Xcode project references the package at `../Packages/CallParserForMac` relative to the demo project directory.

## Usage

Parse the bundled prefix data once, then create a lookup object:

```swift
import CallParser

let prefixData = PrefixFileParser.parse()
let lookup = CallLookup(parsedData: prefixData)

// In an async context:
let hits = await lookup.lookupCall(callSign: "W6OP")
```

`lookupCall` returns an array because a call sign can have multiple matching locations. For local-only work, `parseCallSign(_:)` provides a synchronous lookup; `parseBatch(callSigns:)` and `lookupBatch(callSigns:maxConcurrency:)` handle batches. `lookupCallPairGrouped(spotter:dx:)` returns spotter and DX results separately.

To use QRZ, call `try await lookup.logonToQrz(userId:password:)` with credentials supplied by the app. An active QRZ session is used first unless `useCallParserOnly` was set to `true` when creating the lookup; failed QRZ lookups fall back to local resolution. Call `await lookup.logoffFromQrz()` to clear the local session. Do not put credentials in source control.

For local resolution, an exact BigCTY match takes precedence when BigCTY data is loaded, followed by the bundled prefix parser and then a BigCTY prefix fallback. To download or refresh BigCTY data and use it immediately:

```swift
// In an async throwing context:
lookup.bigCTYData = try await lookup.downloadAndParseBigCTY()
```

The downloaded file is stored in Application Support and loaded on later launches. Debug builds print raw QRZ responses to the console; those responses can include session keys and personal information.

## Testing

Run the package tests from the package directory:

```sh
swift test
```

In a restricted environment where SwiftPM cannot create its own sandbox, use `swift test --disable-sandbox --scratch-path /tmp/callparser-swift-tests` instead. The tests use mock QRZ and geocoding services and do not require credentials.

## Questions

Send bugs, comments, or questions to support@w6op.com.

## Other software

[W6OP](https://w6op.com) also offers xVoiceKeyer and xCW for macOS.

#### 

#### 
