import SwiftUI

/// Epic 02 — small orange capsule overlaid on the mascot's top-trailing
/// corner, showing the total number of items across all non-archived buckets.
///
/// Hidden entirely when the bucket is empty. Over-99 counts render as "99+".
/// The view observes `BucketManager.shared` (`@Observable`) so it redraws
/// automatically as items are added/removed — no notification plumbing needed.
struct BucketBadgeView: View {

    @State private var manager = BucketManager.shared
    let scale: CGFloat

    var body: some View {
        if let text = BucketManager.badgeText(count: manager.totalActiveItemCount()) {
            Text(text)
                .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6 * scale)
                .padding(.vertical, 2 * scale)
                .background {
                    Capsule().fill(Color.orange)
                }
                .overlay {
                    Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
                .accessibilityLabel("Bucket has \(manager.totalActiveItemCount()) items")
        }
    }
}
