import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Main bucket UI — search field + scrollable item list + toolbar.
///
/// Hosted inside `SnorOhPanelView` as the alternate tab. Accepts drops through
/// `BucketDropHandler` with `source = .panel`.
struct BucketView: View {

    let manager: BucketManager
    let storeRootURL: URL

    @State private var query: String = ""
    @State private var dropTargeted = false

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
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visibleItems) { item in
                        BucketCardView(
                            item: item,
                            storeRootURL: storeRootURL,
                            manager: manager
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 240)
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
