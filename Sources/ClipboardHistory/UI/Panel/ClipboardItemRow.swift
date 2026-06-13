import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Memoizes JPEG-thumbnail → NSImage decoding so scrolling never re-decodes. Keyed by item id;
/// the row only ever consumes already-decrypted bytes, so no crypto lives here.
@MainActor
enum ThumbnailImageCache {
    private static let cache = NSCache<NSUUID, NSImage>()

    static func image(for id: UUID, jpeg: Data) -> NSImage? {
        if let cached = cache.object(forKey: id as NSUUID) { return cached }
        guard let image = NSImage(data: jpeg) else { return nil }
        cache.setObject(image, forKey: id as NSUUID)
        return image
    }
}

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

            if item.kind != .text {
                leadingVisual
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    /// Leading thumbnail/icon. Only rendered for image/file kinds (the body gates on kind);
    /// text returns an empty view and never shows.
    @ViewBuilder private var leadingVisual: some View {
        switch item.kind {
        case .text:
            EmptyView()
        case .image:
            if let jpeg = item.thumbnail, let image = ThumbnailImageCache.image(for: item.id, jpeg: jpeg) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholderIcon("photo")
            }
        case .file:
            Image(nsImage: Self.fileIcon(for: item.fileEntries?.first?.uti))
                .resizable().aspectRatio(contentMode: .fit).padding(2)
        }
    }

    private func placeholderIcon(_ symbol: String) -> some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }

    private static func fileIcon(for uti: String?) -> NSImage {
        if let uti, let type = UTType(uti) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(Self.relativeFormatter.localizedString(for: item.lastCapturedAt, relativeTo: Date()))
            if let appName = item.sourceAppName {
                Text("·")
                Text(appName)
            }
            if item.kind != .text {
                Text("·")
                Text(Self.byteFormatter.string(fromByteCount: item.sizeBytes))
            } else if item.isMultiline {
                Text("·")
                Text("\(item.lineCount) lines · \(Self.byteFormatter.string(fromByteCount: item.sizeBytes))")
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
