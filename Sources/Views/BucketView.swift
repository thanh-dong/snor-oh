import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Main bucket UI — search field + scrollable item list + toolbar.
///
/// Hosted inside the standalone `BucketWindow`. Accepts drops through
/// `BucketDropHandler` with `source = .panel`.
struct BucketView: View {

    let manager: BucketManager
    let storeRootURL: URL
    /// When true (standalone BucketWindow), the list expands to fill its
    /// parent window. When false (embedded in a compact context), a 240pt
    /// cap keeps it compact. Defaults to false so existing call sites behave
    /// the same as before.
    var fillAvailable: Bool = false

    @State private var query: String = ""
    @State private var dropTargeted = false
    /// Epic 07 — non-nil when OCRIndex is running a lazy-mode batch after
    /// the user typed a query. Drives the "indexing…" footer so the user
    /// doesn't think the first search is broken.
    @State private var indexingInFlight = false
    /// Epic 07 — brief highlight for the "Reveal Source" jump. Cleared on a
    /// 1.5 s timer so the pulse fades back to the normal card look.
    @State private var highlightedItemID: UUID?

    private var visibleItems: [BucketItem] {
        query.isEmpty ? manager.activeBucket.items : manager.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider().opacity(0.2)

            content
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(dropTargeted ? Color.accentColor.opacity(0.12) : .clear)
                )
                .animation(.easeOut(duration: 0.15), value: dropTargeted)
                .onDrop(
                    of: BucketDropHandler.supportedUTTypes,
                    isTargeted: $dropTargeted
                ) { providers in
                    BucketDropHandler.ingest(providers: providers, source: .panel)
                }

            if indexingInFlight {
                indexingFooter
            }
        }
        .onChange(of: query) { _, newValue in
            triggerLazyOCRIfNeeded(for: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .bucketOCRIndexed)) { _ in
            // Keep the footer visible until we confirm there's nothing left
            // to index; another batch may be queued.
            Task { @MainActor in
                let pending = await OCRIndex.shared.hasPendingIndex(
                    items: manager.activeBucket.items
                )
                indexingInFlight = pending
            }
        }
    }

    private var indexingFooter: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Indexing screenshots for search…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// Epic 07 — lazy OCR gate. Only triggers when the user actually typed
    /// something AND the setting is `.lazy`. Runs in a detached task so the
    /// text field stays responsive.
    private func triggerLazyOCRIfNeeded(for q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            indexingInFlight = false
            return
        }
        guard manager.settings.ocrIndexingMode == .lazy else { return }

        let items = manager.activeBucket.items.filter {
            $0.kind == .image && $0.ocrIndexedAt == nil
        }
        guard !items.isEmpty else { return }
        indexingInFlight = true
        let root = storeRootURL
        Task.detached(priority: .userInitiated) {
            await OCRIndex.shared.ensureIndexed(items: items, storeRootURL: root)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Search…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Menu {
                Button("Clear Unpinned", role: .destructive) {
                    manager.clearUnpinned()
                }
                .disabled(manager.activeBucket.items.filter { !$0.pinned }.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if visibleItems.isEmpty {
            emptyState
                .frame(maxHeight: fillAvailable ? .infinity : nil)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleItems) { item in
                            BucketCardView(
                                item: item,
                                storeRootURL: storeRootURL,
                                manager: manager
                            )
                            .id(item.id)
                            .overlay {
                                if highlightedItemID == item.id {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor, lineWidth: 2)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: fillAvailable ? .infinity : 240)
                .onReceive(NotificationCenter.default.publisher(for: .bucketRevealItem)) { note in
                    guard let id = note.userInfo?["itemID"] as? UUID else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                        highlightedItemID = id
                    }
                    // Pulse off after ~1.5s so the outline fades back to normal.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.easeOut(duration: 0.35)) {
                            highlightedItemID = nil
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "Drop anything here" : "No matches")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if query.isEmpty {
                Text("Files · URLs · images · text")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
    }
}
