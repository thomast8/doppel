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

    func testThePadHasThreeChannels() {
        XCTAssertEqual(MicroChannels.all, 1...3, "the Creator Micro 2 pairs as three Bluetooth devices")
        let state = MicroChannels.parse("instance\told\t7\nclaude\t4\n")
        XCTAssertTrue(state.instances.isEmpty, "a channel the pad does not have is no assignment")
        XCTAssertEqual(state.claude, .off)
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
