import XCTest
@testable import SlurmBarCore

final class HostDiscoveryTests: XCTestCase {
    func testOnlyLiteralAliasesAreSuggested() {
        XCTAssertEqual(HostDiscovery.aliases(in: "Host alpha beta\nHost *.example !bad\nHost = gamma # comment\nMatch exec touch\nHost -bad x/y"), ["alpha", "beta", "gamma"])
    }
}
