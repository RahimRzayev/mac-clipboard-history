import Foundation

/// Serializes the actual file bytes for a file-kind item into a single blob (stored in the
/// encrypted payload file). The manifest — names/UTIs/sizes — lives separately in the row;
/// this is purely the bytes needed to recreate the files on paste-back. Order- and
/// duplicate-preserving (two files can share a name), and a binary plist keeps `Data` inline
/// without base64 bloat.
enum FilePayload {
    static func encode(_ files: [(name: String, data: Data)]) throws -> Data {
        let array = files.map { ["name": $0.name, "data": $0.data] as [String: Any] }
        return try PropertyListSerialization.data(fromPropertyList: array, format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> [(name: String, data: Data)]? {
        guard let array = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [[String: Any]] else { return nil }
        return array.compactMap { entry in
            guard let name = entry["name"] as? String, let bytes = entry["data"] as? Data else {
                return nil
            }
            return (name, bytes)
        }
    }
}
