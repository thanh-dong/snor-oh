import XCTest
@testable import SnorOhSwift

final class ProjectDigestTooltipTests: XCTestCase {

    func makeSnap(tasks: Int = 0, secs: UInt64 = 0, files: Int = 0, sessions: Int = 0) -> DigestSnapshot {
        var d = ProjectDigest(
            projectPath: "/tmp/proj",
            awayWindowStart: Date(timeIntervalSince1970: 1_000_000),
            awayWindowEnd: nil,
            events: []
        )
        for _ in 0..<tasks {
            d.append(ProjectEvent(kind: .task, timestamp: Date(timeIntervalSince1970: 1_000_060),
                                  durationSecs: secs / UInt64(max(tasks, 1)), filesDelta: 0))
        }
        if files != 0 {
            d.append(ProjectEvent(kind: .filesChanged, timestamp: Date(timeIntervalSince1970: 1_000_100),
                                  durationSecs: 0, filesDelta: files))
        }
        for _ in 0..<sessions {
            d.append(ProjectEvent(kind: .sessionEnded, timestamp: Date(timeIntervalSince1970: 1_000_200),
                                  durationSecs: 0, filesDelta: 0))
        }
        return DigestSnapshot(from: d, windowEnd: Date(timeIntervalSince1970: 1_000_300))
    }

    func testFeatureDisabledReturnsEmpty() {
        let snap = makeSnap(tasks: 1, secs: 60)
        XCTAssertEqual(tooltipText(snapshot: snap, enabled: false), "")
    }

    func testNoSnapshotReturnsEmpty() {
        XCTAssertEqual(tooltipText(snapshot: nil, enabled: true), "")
    }

    func testTasksOnly() {
        let snap = makeSnap(tasks: 2, secs: 480)  // 8 minutes total
        let txt = tooltipText(snapshot: snap, enabled: true)
        XCTAssertTrue(txt.contains("2 tasks completed"))
        XCTAssertTrue(txt.contains("8m"))
    }

    func testFilesOnly() {
        let snap = makeSnap(files: 3)
        let txt = tooltipText(snapshot: snap, enabled: true)
        XCTAssertTrue(txt.contains("3 files changed"))
    }

    func testTasksAndFiles() {
        let snap = makeSnap(tasks: 1, secs: 120, files: 5)
        let txt = tooltipText(snapshot: snap, enabled: true)
        XCTAssertTrue(txt.contains("1 task"))
        XCTAssertTrue(txt.contains("5 files"))
    }

    func testHeaderIncludesWindowRange() {
        let snap = makeSnap(tasks: 1, secs: 60)
        let txt = tooltipText(snapshot: snap, enabled: true)
        XCTAssertTrue(txt.contains("While you were away"))
    }
}
