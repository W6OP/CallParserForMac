# CallParser

Application for parsing Amateur Radio callsigns to determine origin and location.
### CallParser [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://en.wikipedia.org/wiki/MIT_License)

#### Mac version of CallParser - Amateur Radio call lookup program

##### Built on:

*  macOS 11.2.1
*  Xcode Version 12.4 (12D4e)
*  Swift 5.3 / AppKit

##### Runs on:
* macOS 10.15 and higher

##### Usage:
CallParser is a Swift Package allowing an application to determine the country and other information about an Amateur Radio call sign. There are two constructors, on both you create an instance of the PrefixFileParser() and pass it in. On the second constructor you can also pass in credentials for
  QRZ.com. You can use the first constructor and call the logonToQrz() function if you prefer. If
  valid credentials are passed in the CallParser will use QRZ.com as the primary source of call sign data with the CallParser as the secondary source. If no credentials are supplied then only the CallParser output will be used. You can set the CallParser to be the primary lookup by setting the useCallParserOnly flag even if valid credentials have been supplied.


##### Comments / Questions
Please send any bugs / comments / questions to support@w6op.com

##### Credits:

##### Other software 
[![W6OP](https://img.shields.io/badge/W6OP-xVoiceKeyer,_xCW-informational)](https://w6op.com) A Mac-based Voice Keyer and a CW Keyer.  

---
##### 1.0.2 Release Notes
* initial release of package

##### 1.0.3 Release Notes
* bug fixes in package definition

##### 1.0.4 Release Notes
* bug fixes in package definition

##### 1.0.5 Release Notes
* bug fixes in resource definition

##### 1.0.6 Release Notes
* bug fixes reading resource bundle

##### 1.0.7 Release Notes
* fixed typos in resource bundle

#### 1.0.8 Release Notes
* fixed major bug in mask creation

#### 1.0.9 Release Notes
* old comment cleanup

#### 1.0.10 Release Notes
* bug fix for synchronous calls

#### 1.0.11 Release Notes
* bug fixes parsing the masks

#### 1.1.00 Release Notes
* branch from main
* added async/await code
* this version on requires MacOS 12 or higher
* Swift 5.5
* Xcode 13.1

#### 1.1.1 Release Notes
* bug fix

#### 1.1.2 Release Notes
* Fixed to work with SwiftUI and non SwiftUI applications

#### 1.1.3 Release Notes
* Unify tag and release version

#### 1.2.0 Release notes
* Froze main branch
* Branched to add async operations
* Added QRZ.com lookup

### 1.2.1 Release Notes
* Added useCallParserOnly flag

### 1.2.2 Release Notes
* Additional error processing

### 1.2.3 Release Notes
* Experimenting

### 1.3.0 Release Notes
* Fixed cache checking.
* Enhance lookup code.

### 1.3.1 Release Notes
* Fully works in SwiftUI model.
* Handles QRZ.com not found - reverts to CallParser.

#### 1.3.5 Release Notes
* Added supporting code for callback

#### 1.3.6 Release Notes
* Disabled the cache for testing xCluster

#### 1.3.7 Release Notes
* Bug fix for call back.

#### 1.4.1 Release Notes
* Added callback for session key success/failure.

#### 1.4.5 Release Notes
* Upgraded syntax for Swift 6
* Added city, county, state to hit for QRZ lookups.

#### 1.4.6 Release Notes
* Replaced fatalError with logging statement.

#### 1.4.7 Release Notes
* Added iOS 13 compatibility

#### 1.4.8 Release Notes
* Removed unused Cocoa imports

#### 1.4.9 Release Notes
* Minimum iOS release now 14

#### 1.4.9 Release Notes
* Minimum iOS release now 15.0

#### 2.0.1 Release Notes
* Converted callbacks to continuations.
* Breaking change. All client call lookups using callbacks will fail.
