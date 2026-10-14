import XCTest
@testable import DoppelMenuBar

final class CLIErrorReportTests: XCTestCase {
    func testDiskSpaceFailureSurvivesProgressAndSecondaryUnzipError() {
        let progress = "Downloading ChatGPT 26.1007.71326…\n% Total % Received % Xferd\nDload  Upload\n"
            + String(repeating: "\r29 686M 29 200M 5772k", count: 150)
        let failure = progress + "\nditto: /Users/test/ChatGPT.app: No space left on device\n"
            + "ditto: Couldn't read pkzip signature.\ndoppel: unpacking ChatGPT 26.1007.71326 failed\n"
        XCTAssertEqual(CLIErrorReport.summary(failure),
                       "Your Mac ran out of disk space. Free up some space, then try again.")
    }

    func testPrefersFinalDoppelErrorOverToolOutput() {
        let failure = "curl: (28) Operation timed out\ndoppel: downloading ChatGPT failed; the partial download was kept for retry\n"
        XCTAssertEqual(CLIErrorReport.summary(failure),
                       "downloading ChatGPT failed; the partial download was kept for retry")
    }

    func testInstanceNameCannotBeMistakenForDiskSpaceFailure() {
        XCTAssertEqual(CLIErrorReport.summary("doppel: 'No space left on device' is not installed"),
                       "'No space left on device' is not installed")
    }

    func testPreservesShortActionableMessages() {
        XCTAssertEqual(CLIErrorReport.summary("  Another update is already in progress.\n"),
                       "Another update is already in progress.")
    }

    func testBoundsLongErrorsAndDoesNotDisplayUnstructuredLogs() {
        XCTAssertEqual(CLIErrorReport.summary("doppel: " + String(repeating: "x", count: 5_000)).count, 500)
        for output in ["", String(repeating: "trace line\n", count: 1_000), "% Total\nDload  Upload\n100 686M"] {
            XCTAssertEqual(CLIErrorReport.summary(output),
                           "Doppel could not complete the operation. Check its local logs for details.")
        }
    }

    func testExistingLogIsMadePrivateBeforeAppending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("cli-errors.log")
        try "previous failure\n".write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        try CLIErrorReport.record("new failure", arguments: ["update", "prepare"], to: log)
        let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let contents = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("previous failure\n"))
        XCTAssertTrue(contents.contains("new failure"))
    }

    func testRecordsOriginalDiagnosticsWithoutOverwritingPreviousFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = directory.appendingPathComponent("cli-errors.log")
        try CLIErrorReport.record("% Total\rprogress\nditto: No space left on device", arguments: ["update", "prepare"], to: log)
        try CLIErrorReport.record("doppel: another failure", arguments: ["rebuild", "Test"], to: log)
        let contents = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(contents.contains("doppel update prepare\n% Total\rprogress\nditto: No space left on device"))
        XCTAssertTrue(contents.contains("doppel rebuild Test\ndoppel: another failure"))
        let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
