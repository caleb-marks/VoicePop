import XCTest
@testable import PopcornCore

final class ModelIdentityTests: XCTestCase {
    func testPackagedVariantIsTheSameModel() {
        XCTAssertTrue(ModelIdentity.same("parakeet-tdt-0.6b-v3-int8-prepacked", "parakeet-tdt-0.6b-v3-int8"))
        XCTAssertTrue(ModelIdentity.isInstalled("parakeet-tdt-0.6b-v3-int8", in: ["parakeet-tdt-0.6b-v3-int8-prepacked"]))
        XCTAssertTrue(ModelIdentity.isInstalled("parakeet-tdt-0.6b-v3-int8-prepacked", in: ["parakeet-tdt-0.6b-v3-int8"]))
    }

    func testQuantizedSiblingIsNotTheSameModel() {
        XCTAssertFalse(ModelIdentity.same("parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v3-int8"))
        XCTAssertFalse(ModelIdentity.isInstalled("parakeet-tdt-0.6b-v3", in: ["parakeet-tdt-0.6b-v3-int8"]))
        XCTAssertFalse(ModelIdentity.isInstalled("small", in: ["small.en"]))
    }
}
