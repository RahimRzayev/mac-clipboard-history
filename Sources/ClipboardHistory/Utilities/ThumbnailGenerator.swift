import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates a small JPEG thumbnail + the source pixel dimensions from raw image bytes,
/// using ImageIO so we never fully decode a multi-MB image into an NSImage. The thumbnail
/// is held as plaintext in the in-memory item and encrypted at the storage boundary.
enum ThumbnailGenerator {
    static func make(from data: Data, maxPixel: CGFloat = 256, quality: CGFloat = 0.7)
        -> (jpeg: Data, pixelSize: CGSize)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let pixelSize = sourcePixelSize(source)

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let size = pixelSize ?? CGSize(width: thumb.width, height: thumb.height)
        return (outData as Data, size)
    }

    private static func sourcePixelSize(_ source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Double,
              let height = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return CGSize(width: width, height: height)
    }
}
