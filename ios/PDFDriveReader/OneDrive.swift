import Foundation

struct DriveItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let createdDateTime: Date
    let file: FileFacet?
    let downloadURL: String?

    struct FileFacet: Decodable, Hashable {}

    enum CodingKeys: String, CodingKey {
        case id, name, createdDateTime, file
        case downloadURL = "@microsoft.graph.downloadUrl"
    }

    /// File name without ".pdf", read-friendly.
    var title: String {
        var t = name
        if t.lowercased().hasSuffix(".pdf") { t.removeLast(4) }
        return t.replacingOccurrences(of: "_", with: " ")
    }
}

enum OneDriveError: LocalizedError {
    case folderNotFound
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .folderNotFound: return "That OneDrive folder wasn't found. Check the folder path in Settings."
        case .http(let code): return "OneDrive request failed (\(code))."
        }
    }
}

/// Minimal Microsoft Graph client for listing and downloading PDFs.
enum OneDrive {
    private static let graph = "https://graph.microsoft.com/v1.0"

    static func listPDFs(folder: String) async throws -> [DriveItem] {
        let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var next: String?
        if trimmed.isEmpty {
            next = graph + "/me/drive/root/children?$top=200"
        } else {
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))
            let encoded = trimmed.split(separator: "/")
                .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
                .joined(separator: "/")
            next = graph + "/me/drive/root:/\(encoded):/children?$top=200"
        }

        var items: [DriveItem] = []
        while let url = next {
            let page: Page = try decoder.decode(Page.self, from: try await get(url))
            items += page.value
            next = page.nextLink
        }
        return items.filter { $0.file != nil && $0.name.lowercased().hasSuffix(".pdf") }
    }

    static func download(_ item: DriveItem) async throws -> Data {
        // Ask for fresh metadata: the pre-signed download link expires after about an hour.
        let fresh = try decoder.decode(DriveItem.self, from: try await get(graph + "/me/drive/items/\(item.id)"))
        guard let link = fresh.downloadURL, let url = URL(string: link) else { throw OneDriveError.http(404) }
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw OneDriveError.http(status) }
        return data
    }

    private static func get(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw OneDriveError.http(400) }
        let token = try await OneDriveAuth.shared.token()
        var request = URLRequest(url: u)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw OneDriveError.folderNotFound }
        guard (200..<300).contains(status) else { throw OneDriveError.http(status) }
        return data
    }

    private struct Page: Decodable {
        let value: [DriveItem]
        let nextLink: String?
        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "Unrecognised date \(s)"))
        }
        return decoder
    }()
}
