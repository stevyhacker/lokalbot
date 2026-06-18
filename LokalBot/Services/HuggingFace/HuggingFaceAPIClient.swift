import Foundation

/// Stateless client for HuggingFace's public model REST API. Holds one
/// short-timeout, non-caching `URLSession` so the browse flow always shows a
/// fresh model list and a stalled network can never hang the UI for long.
///
/// Decoupled from `ModelCatalog`/`ModelDownloadManager` on purpose: it returns
/// plain value types and a directly-downloadable URL, leaving download policy
/// (destination, naming, progress) to the existing download manager.
struct HuggingFaceAPIClient {

    /// Failure surfaced to the browse UI. `LocalizedError` so the search
    /// service can publish `errorDescription` straight into `errorMessage`.
    enum APIError: LocalizedError {
        case invalidURL
        case rateLimited
        case http(status: Int)
        case decoding(Error)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Couldn't build the HuggingFace request URL."
            case .rateLimited:
                return "HuggingFace is rate-limiting requests — wait a moment and try again."
            case .http(let status):
                return "HuggingFace returned an unexpected response (HTTP \(status))."
            case .decoding:
                return "Couldn't read HuggingFace's response."
            case .transport(let error):
                return error.localizedDescription
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = HuggingFaceAPIClient.defaultSession()) {
        self.session = session
    }

    /// Ephemeral + cache-defeating so model lists are never stale; the 20 s
    /// request timeout keeps a slow network from wedging the browse sheet.
    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// Search GGUF model repositories, most-downloaded first.
    ///
    /// `direction=-1` is required: `sort=downloads` alone returns ascending
    /// (least-popular) results, which is the opposite of what a "find a model"
    /// browse wants — so popular repos would never surface without it.
    func searchModels(query: String, limit: Int = 20) async throws -> [HFModelSummary] {
        guard var components = URLComponents(string: "https://huggingface.co/api/models") else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(max(1, limit))),
        ]
        guard let url = components.url else { throw APIError.invalidURL }
        return try await fetch([HFModelSummary].self, from: url)
    }

    /// List the `.gguf` files in a repository.
    ///
    /// Reads the plain model record's `siblings`, which carry only `rfilename`
    /// (no blob metadata) — hence `HFFile.sizeBytes` is usually nil here. Files
    /// are returned in natural filename order so quantization variants group
    /// sensibly in the UI.
    func files(modelID: String) async throws -> [HFFile] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        // modelID is "owner/repo"; its slash is a real path separator, so set it
        // via `path` (URLComponents percent-encodes only the unsafe characters).
        components.path = "/api/models/\(modelID)"
        guard let url = components.url else { throw APIError.invalidURL }

        let record = try await fetch(ModelRecord.self, from: url)
        return record.siblings
            .filter { $0.rfilename.lowercased().hasSuffix(".gguf") }
            .map { HFFile(id: $0.rfilename, modelID: modelID, sizeBytes: $0.size) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    // MARK: - Request plumbing

    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // URLError.cancelled lands here too; the caller distinguishes it via
            // Task.isCancelled so a superseded request stays silent.
            throw APIError.transport(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw APIError.rateLimited }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(status: http.statusCode)
            }
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Identifies the app to HuggingFace so anonymous traffic is attributable
    /// and less likely to hit shared rate limits.
    private static let userAgent = AppIdentifiers.bundleID

    /// Wire shape of `GET /api/models/<id>` — only `siblings` is consumed; the
    /// many other keys are ignored by `JSONDecoder`.
    private struct ModelRecord: Decodable {
        let siblings: [Sibling]

        struct Sibling: Decodable {
            let rfilename: String
            let size: Int?
        }
    }
}

// MARK: - Value types

/// One repository from `GET /api/models?filter=gguf&search=…&sort=downloads`.
/// `Decodable` maps the API's `id`/`downloads`/`likes` directly; a missing
/// count decodes to 0 so one absent field never fails the whole list.
struct HFModelSummary: Decodable, Identifiable, Hashable {
    /// Canonical repository id, e.g. `unsloth/Qwen3.5-0.8B-GGUF`.
    let id: String
    let downloads: Int
    let likes: Int

    init(id: String, downloads: Int, likes: Int) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try container.decodeIfPresent(Int.self, forKey: .likes) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, downloads, likes
    }
}

/// One downloadable `.gguf` file inside a repository.
struct HFFile: Identifiable, Hashable {
    /// Repo-relative path (`rfilename`), e.g. `Qwen3.5-0.8B-Q4_K_M.gguf` — or
    /// `gguf/model-Q4_K_M.gguf` when a repo nests files in a subfolder.
    let id: String
    /// Owning repository id (`owner/repo`); needed to build the resolve URL.
    let modelID: String
    /// Byte size when the API reports it; nil from the plain model endpoint,
    /// whose `siblings` omit blob metadata.
    let sizeBytes: Int?

    /// Direct download URL on HuggingFace's `resolve` endpoint. `URLSession`
    /// follows the CDN redirect automatically, so this is usable as-is by a
    /// `downloadTask`. Built via `URLComponents` so nested paths and unusual
    /// characters are percent-encoded correctly.
    var downloadURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(modelID)/resolve/main/\(id)"
        // `url` is nil only for a malformed scheme/host, both constants here, so
        // the literal fallback is unreachable in practice.
        return components.url ?? URL(string: "https://huggingface.co")!
    }

    /// Leaf filename — repos sometimes nest files (e.g. `gguf/model.gguf`), and
    /// downloads should land flat under `<storage>/models/`.
    var fileName: String {
        (id as NSString).lastPathComponent
    }

    /// Human-readable size, or nil when the endpoint didn't report one.
    var sizeLabel: String? {
        guard let sizeBytes else { return nil }
        return Int64(sizeBytes).formatted(.byteCount(style: .file))
    }
}
