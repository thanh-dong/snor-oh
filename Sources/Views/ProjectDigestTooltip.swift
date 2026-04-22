import Foundation

/// Pure function. Safe to call at render time — no IO, no allocations beyond
/// the returned string. Returns "" when disabled or no snapshot.
func tooltipText(snapshot: DigestSnapshot?, enabled: Bool) -> String {
    guard enabled, let s = snapshot else { return "" }

    let df = DateFormatter()
    df.dateFormat = "HH:mm"
    let range = "\(df.string(from: s.awayWindowStart))–\(df.string(from: s.awayWindowEnd))"

    var lines = ["While you were away (\(range)):"]
    var anyContent = false

    if s.taskCount > 0 {
        let mins = max(1, Int(s.totalTaskSecs / 60))
        lines.append("▲ \(s.taskCount) task\(s.taskCount == 1 ? "" : "s") completed · \(mins)m total")
        anyContent = true
    }
    if s.filesDelta != 0 {
        let n = abs(s.filesDelta)
        lines.append("▲ \(n) file\(n == 1 ? "" : "s") changed")
        anyContent = true
    }
    if s.sessionsEnded > 0 {
        lines.append("● \(s.sessionsEnded) session\(s.sessionsEnded == 1 ? "" : "s") ended")
        anyContent = true
    }
    if !anyContent {
        lines.append("no activity on this project")
    }
    if let last = s.lastActivity {
        lines.append("Last active: \(df.string(from: last))")
    }
    return lines.joined(separator: "\n")
}
