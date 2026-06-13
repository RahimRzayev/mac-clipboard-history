import AppKit
import Combine

/// Drives the popup panel: query, filtered results (pinned above recents), and a single
/// canonical selection (spec §10). Keyboard owns selection; hover updates it only on real
/// mouse movement, never because the list scrolled under a stationary cursor.
@MainActor
final class PanelViewModel: ObservableObject {
    @Published var query = "" {
        didSet {
            refilter()
            // Spotlight behavior: every query edit (including Escape-clear) snaps the
            // selection to the first result. Retaining it would leave Enter acting on an
            // off-screen highlight after the list re-expands (spec §10: "Enter always
            // acts on the visible highlight").
            if oldValue != query {
                selectionID = flatResults.first?.id
            }
        }
    }
    @Published private(set) var pinnedResults: [ClipboardItem] = []
    @Published private(set) var recentResults: [ClipboardItem] = []
    @Published var selectionID: UUID?
    /// True while Cmd alone is held — rows 1–9 show their quick-paste badge (spec §10).
    @Published var isCmdHeld = false
    /// Bumped on every panel open; the view re-asserts search-field focus on change.
    /// (onAppear fires only on the FIRST open — the hosting view is installed once — and
    /// selectionID often doesn't change across a close/reopen, so neither can drive focus.)
    @Published private(set) var focusToken = 0

    let store: ClipboardStore
    var onPaste: (ClipboardItem) -> Void = { _ in }
    var onCopyOnly: (ClipboardItem) -> Void = { _ in }

    private var cancellables: Set<AnyCancellable> = []
    private var lastHoverMouseLocation: NSPoint?

    init(store: ClipboardStore) {
        self.store = store
        store.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refilter()
            }
            .store(in: &cancellables)
        refilter()
    }

    /// Pinned first, then recents — the ordering used for arrow keys and Cmd+1–9.
    var flatResults: [ClipboardItem] {
        pinnedResults + recentResults
    }

    var selectedItem: ClipboardItem? {
        flatResults.first { $0.id == selectionID }
    }

    /// Query and selection reset every time the panel opens (spec §10).
    func reset() {
        lastHoverMouseLocation = NSEvent.mouseLocation
        // Initialize from reality: the panel is usually opened via a Cmd-chord hotkey,
        // so Cmd may be physically down right now.
        isCmdHeld = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        query = ""
        selectionID = flatResults.first?.id
        focusToken += 1
    }

    func moveSelection(_ delta: Int) {
        // Snapshot the cursor on every keyboard move: rows scrolling under a stationary
        // cursor fire onHover with a stale comparison point otherwise, letting hover
        // steal the selection back from the arrow keys (spec §10).
        lastHoverMouseLocation = NSEvent.mouseLocation
        let flat = flatResults
        guard !flat.isEmpty else { return }
        let current = flat.firstIndex { $0.id == selectionID } ?? -1
        let next = min(max(current + delta, 0), flat.count - 1)
        selectionID = flat[next].id
    }

    /// Hover selection, gated on actual mouse movement (spec §10 selection model).
    func hoverSelect(_ id: UUID) {
        let location = NSEvent.mouseLocation
        if let last = lastHoverMouseLocation,
           abs(last.x - location.x) < 2, abs(last.y - location.y) < 2 {
            return
        }
        lastHoverMouseLocation = location
        selectionID = id
    }

    func confirmSelection() {
        guard let item = selectedItem else { return }
        onPaste(item)
    }

    func copySelectedOnly() {
        guard let item = selectedItem else { return }
        onCopyOnly(item)
    }

    func paste(_ item: ClipboardItem) {
        onPaste(item)
    }

    func pasteVisibleIndex(_ index: Int) {
        let flat = flatResults
        guard index >= 0, index < flat.count else { return }
        onPaste(flat[index])
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        delete(item)
    }

    func delete(_ item: ClipboardItem) {
        let flat = flatResults
        if let index = flat.firstIndex(of: item) {
            let next = flat.indices.contains(index + 1) ? flat[index + 1].id
                     : (index > 0 ? flat[index - 1].id : nil)
            if selectionID == item.id {
                selectionID = next
            }
        }
        store.delete(id: item.id)
    }

    func togglePinSelected() {
        guard let item = selectedItem else { return }
        togglePin(item)
    }

    func togglePin(_ item: ClipboardItem) {
        store.setPinned(id: item.id, !item.isPinned)
    }

    private func refilter() {
        let matches = store.search(query)
        pinnedResults = matches.filter(\.isPinned)
        recentResults = matches.filter { !$0.isPinned }
        let flat = flatResults
        if selectionID == nil || !flat.contains(where: { $0.id == selectionID }) {
            selectionID = flat.first?.id
        }
    }
}
