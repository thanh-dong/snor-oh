import AppKit
import Quartz

/// Singleton helper that fronts `QLPreviewPanel.shared()` for the Bucket UI.
///
/// Works around two annoyances:
///   1. `QLPreviewPanel` is a shared panel that requires a data source on every
///      show — a stateless call site (`QuickLookPreviewer.shared.show(url:)`)
///      is simpler than wiring a dedicated data-source object per view.
///   2. First-responder handoff for `QLPreviewPanelController` is awkward from
///      SwiftUI. We bypass it: set the data source directly and call
///      `makeKeyAndOrderFront(_:)`.
@MainActor
final class QuickLookPreviewer: NSObject, QLPreviewPanelDataSource {

    static let shared = QuickLookPreviewer()

    private var url: URL?

    private override init() {
        super.init()
    }

    func show(url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        (url ?? URL(fileURLWithPath: "/")) as NSURL
    }
}
