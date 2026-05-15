// Placeholder so the test target compiles against the v0 scaffold.
// Real coverage lands in issue #3 (NodeRegistry tests).
//
// Note: `swift test` requires Xcode (XCTest is not bundled with the macOS
// Command Line Tools toolchain). CI on `macos-14` has Xcode and will run
// this. Locally, install Xcode and `xcode-select -s /Applications/Xcode.app`
// to run tests, otherwise this file is build-time-only.

import XCTest

final class PlaceholderTests: XCTestCase {
    func testTrue() {
        XCTAssertTrue(true)
    }
}
