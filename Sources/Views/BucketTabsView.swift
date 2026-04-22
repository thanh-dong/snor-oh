import SwiftUI

/// Horizontal pill tab bar for switching between active buckets.
///
/// Phase 4 wires the create popover on `[+]` and hosts the delete
/// confirmation sheet at the bar level. Each pill's rename/context-menu
/// behaviour lives in `BucketPillTab`.
@MainActor
struct BucketTabsView: View {

    let manager: BucketManager
    /// Optional programmatic override for the `[+]` button. When set,
    /// suppresses the built-in create popover. Used by tests.
    var onCreateRequest: (() -> Void)? = nil

    @State private var showCreate: Bool = false
    @State private var deletingBucketID: UUID? = nil

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(manager.activeBuckets) { bucket in
                        BucketPillTab(
                            bucket: bucket,
                            isActive: bucket.id == manager.activeBucketID,
                            manager: manager,
                            onTap: { manager.setActiveBucket(id: bucket.id) },
                            onRequestDelete: { deletingBucketID = bucket.id }
                        )
                    }
                }
                .padding(.horizontal, 4)
                .animation(.easeInOut(duration: 0.18), value: manager.activeBucketID)
            }

            Button(action: handleCreateTap) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("New bucket")
            .popover(isPresented: $showCreate, arrowEdge: .top) {
                BucketCreateSheet(isPresented: $showCreate) { name, color, emoji in
                    let id = manager.createBucket(name: name, colorHex: color, emoji: emoji)
                    manager.setActiveBucket(id: id)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Empty space around the pill tabs doubles as a window-drag grip.
        // Pills and the `+` button claim mouseDown via SwiftUI hit-testing,
        // so only truly empty space falls through to `WindowDragArea`.
        .background(WindowDragArea())
        .sheet(
            isPresented: Binding(
                get: { deletingBucketID != nil },
                set: { if !$0 { deletingBucketID = nil } }
            )
        ) {
            if let id = deletingBucketID {
                BucketDeleteSheet(
                    manager: manager,
                    targetID: id,
                    isPresented: Binding(
                        get: { deletingBucketID != nil },
                        set: { if !$0 { deletingBucketID = nil } }
                    )
                )
            }
        }
    }

    private func handleCreateTap() {
        if let override = onCreateRequest {
            override()
        } else {
            showCreate = true
        }
    }
}
