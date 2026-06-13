import SwiftUI

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let quickPasteNumber: Int?
    var onHover: () -> Void
    var onTap: () -> Void
    var onPinToggle: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let quickPasteNumber {
                Text("⌘\(quickPasteNumber)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .center)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.preview)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                metadata
            }

            if item.isPinned && !hovering {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }

            if hovering {
                HStack(spacing: 6) {
                    iconButton(
                        systemName: item.isPinned ? "pin.slash" : "pin",
                        help: item.isPinned ? "Unpin" : "Pin",
                        action: onPinToggle
                    )
                    iconButton(systemName: "trash", help: "Delete", action: onDelete)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovering in
            hovering = isHovering
            if isHovering {
                onHover()
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(Self.relativeFormatter.localizedString(for: item.lastCapturedAt, relativeTo: Date()))
            if let appName = item.sourceAppName {
                Text("·")
                Text(appName)
            }
            if item.isMultiline {
                Text("·")
                Text("\(item.lineCount) lines · \(Self.byteFormatter.string(fromByteCount: Int64(item.sizeBytes)))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
