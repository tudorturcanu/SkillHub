import XCTest
#if canImport(SkillKitLib)
@testable import SkillKitLib
#else
@testable import SkillKit
#endif

final class AgentBinaryResolverTests: XCTestCase {

    func testNvmVersionsSortNumericallyNewestFirst() {
        let dirs = ["v9.11.2", "v22.1.0", "v18.20.4", "v20.9.0", "v22.10.0"]
        XCTAssertEqual(
            AgentBinaryResolver.sortedNewestFirst(dirs),
            ["v22.10.0", "v22.1.0", "v20.9.0", "v18.20.4", "v9.11.2"]
        )
    }
}
