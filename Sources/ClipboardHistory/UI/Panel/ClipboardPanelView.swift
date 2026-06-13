import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var viewModel: PanelViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if viewModel.flatResults.isEmpty {
                emptyState
            } else {
                resultsList
            }
            Divider()
            footer
        }
        .frame(width: PanelController.panelSize.width, height: PanelController.panelSize.height)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .onAppear { searchFocused = true }
        // Re-focus on every panel open: reset() bumps the token. (onAppear only fires on
        // the first open — the hosting view is installed once and the panel orders out
        // rather than closing.)
        .onChange(of: viewModel.focusToken) { _, _ in searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search clipboard history", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !viewModel.pinnedResults.isEmpty {
                        sectionHeader("Pinned")
                        rows(viewModel.pinnedResults, indexOffset: 0)
                    }
                    if !viewModel.recentResults.isEmpty {
                        sectionHeader("Recent")
                        rows(viewModel.recentResults, indexOffset: viewModel.pinnedResults.count)
                    }
                }
                .padding(8)
            }
            .onChange(of: viewModel.selectionID) { _, newValue in
                if let newValue {
                    proxy.scrollTo(newValue, anchor: nil)
                }
            }
        }
    }

    private func rows(_ items: [ClipboardItem], indexOffset: Int) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let flatIndex = indexOffset + index
            ClipboardItemRow(
                item: item,
                isSelected: viewModel.selectionID == item.id,
                quickPasteNumber: viewModel.isCmdHeld && flatIndex < 9 ? flatIndex + 1 : nil,
                onHover: { viewModel.hoverSelect(item.id) },
                onTap: { viewModel.paste(item) },
                onPinToggle: { viewModel.togglePin(item) },
                onDelete: { viewModel.delete(item) }
            )
            .id(item.id)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(viewModel.query.isEmpty ? "No clipboard history yet" : "No matches")
                .foregroundStyle(.secondary)
            if viewModel.query.isEmpty {
                Text("Copy some text and it will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            keyHint("↩", "paste")
            keyHint("⌥↩", "copy")
            keyHint("⌘⌫", "delete")
            keyHint("⌘P", "pin")
            keyHint("⌘1–9", "quick paste")
            Spacer()
            keyHint("esc", "close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// Proper panel material backdrop (SwiftUI materials alone don't blend behind a window).
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
