import XCTest
@testable import SnorOhSwift

/// Regression coverage for the v0.6.1 launch-hang bug: on Macs with >~600
/// running processes, `ps -axo` produced >64 KB of stdout, overflowed the
/// pipe buffer, and deadlocked `waitUntilExit()` — freezing the main thread
/// mid-launch so the menu bar icon never appeared. `ProcessRunner` is the
/// canonical safe wrapper; this test enforces that it drains the pipe
/// before waiting.
final class ProcessRunnerTests: XCTestCase {
    /// Produces 256 KB of stdout — 4× the macOS pipe buffer. If the helper
    /// ever regresses to waiting-before-draining, this test hangs instead
    /// of failing, so we give it an explicit deadline via XCTestExpectation.
    func test_runCapture_handlesOutputLargerThanPipeBuffer() throws {
        let chunk = String(repeating: "x", count: 1024) + "\n"
        let repeats = 256   // 256 KB — comfortably exceeds the 64 KB pipe buffer
        let script = "for i in $(seq 1 \(repeats)); do printf %s '\(chunk)'; done"

        let expectation = expectation(description: "runCapture returns before deadline")
        var result: ProcessRunner.Result?
        DispatchQueue.global().async {
            result = ProcessRunner.runCapture(
                launchPath: "/bin/sh",
                arguments: ["-c", script]
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10.0)

        let r = try XCTUnwrap(result, "ProcessRunner deadlocked on large stdout")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.stdout.count, chunk.utf8.count * repeats)
    }

    func test_captureString_returnsNilOnNonZeroExit() {
        let out = ProcessRunner.captureString(launchPath: "/bin/sh", arguments: ["-c", "exit 3"])
        XCTAssertNil(out)
    }

    func test_captureString_trimsWhitespace() {
        let out = ProcessRunner.captureString(launchPath: "/bin/echo", arguments: ["  hello  "])
        XCTAssertEqual(out, "hello")
    }

    func test_captureString_returnsNilWhenBinaryMissing() {
        let out = ProcessRunner.captureString(launchPath: "/does/not/exist", arguments: [])
        XCTAssertNil(out)
    }
}
