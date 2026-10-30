import XCTest
@testable import DoppelMenuBar

final class MicroChannelsTests: XCTestCase {
    func testReadsInstanceChannelsAndClaudeCode() {
        let state = MicroChannels.parse("instance\tpersonal\t3\ninstance\tveridue\t1\nclaude\t2\n")
        XCTAssertEqual(state.instances, ["personal": 3, "veridue": 1])
        XCTAssertEqual(state.claude, .channel(2))
        XCTAssertEqual(state.holder(of: 3), .instance("personal"))
        XCTAssertEqual(state.holder(of: 2), .claude)
        XCTAssertEqual(state.holder(of: 5), .free)
    }

    func testClaudeStates() {
        XCTAssertEqual(MicroChannels.parse("claude\toff\n").claude, .off)
        XCTAssertEqual(MicroChannels.parse("claude\tany\n").claude, .everyChannel)
        XCTAssertEqual(MicroChannels.parse("").claude, .off, "an older CLI says nothing; treat it as not set up")
    }

    func testIgnoresMalformedRows() {
        let state = MicroChannels.parse("instance\tbad\t0\ninstance\tx\nclaude\t12\nnoise\n")
        XCTAssertTrue(state.instances.isEmpty)
        XCTAssertEqual(state.claude, .off)
    }
}
