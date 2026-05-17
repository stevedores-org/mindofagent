import XCTest
@testable import MindOfAgentCore

final class HardwareProfileTests: XCTestCase {

    // MARK: - txtRecord

    func testTxtRecordIncludesPublicFieldsOnly() {
        let profile = HardwareProfile(
            hostname: "alice-mbp",
            chip: "Apple M4 Max",
            memoryGB: 64,
            serialNumber: "C02ABC123XYZ",
            osVersion: "Version 14.6.1 (Build 23G93)",
            model: "MacBookPro18,4"
        )

        let txt = profile.txtRecord

        XCTAssertEqual(txt["host"], "alice-mbp")
        XCTAssertEqual(txt["chip"], "Apple M4 Max")
        XCTAssertEqual(txt["mem_gb"], "64")
        XCTAssertEqual(txt["model"], "MacBookPro18,4")
        // serialNumber is PII — must not leak into Bonjour.
        XCTAssertNil(txt["serial"])
        XCTAssertNil(txt["serial_number"])
        // osVersion is excluded to keep the TXT record small.
        XCTAssertNil(txt["os"])
    }

    func testTxtRecordOmitsNilFields() {
        let profile = HardwareProfile(
            hostname: "minimal-host",
            chip: nil,
            memoryGB: nil,
            serialNumber: nil,
            osVersion: "Version 14.6.1",
            model: nil
        )

        let txt = profile.txtRecord

        XCTAssertEqual(txt, ["host": "minimal-host"])
    }

    // MARK: - live smoke test

    /// Smoke test against the real host. Doesn't assert specific values
    /// because tests have to pass on any Mac — just pins the invariants
    /// the menu UI relies on.
    func testLiveProfileHasRequiredFields() {
        let profile = HardwareProfiler.getProfile()

        XCTAssertFalse(profile.hostname.isEmpty, "hostname must always populate")
        XCTAssertFalse(profile.osVersion.isEmpty, "osVersion comes from ProcessInfo, must always populate")

        // On a real Mac all four optional fields should populate. If one
        // fails we want to know in CI — but we don't fail the test, so
        // sandboxed CI environments where IOKit is denied still pass.
        if profile.serialNumber == nil {
            print("⚠️ serialNumber unavailable — likely sandboxed environment")
        }
        if profile.chip == nil {
            print("⚠️ chip unavailable — machdep.cpu.brand_string sysctl failed")
        }
        if profile.memoryGB == nil {
            print("⚠️ memoryGB unavailable — hw.memsize sysctl failed")
        }
        if profile.model == nil {
            print("⚠️ model unavailable — hw.model sysctl failed")
        }
    }
}
