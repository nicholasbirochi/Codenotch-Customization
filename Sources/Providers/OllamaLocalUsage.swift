import Foundation

enum OllamaLocalUsage {
    private struct Response: Decodable {
        struct Model: Decodable {
            struct Details: Decodable {
                let quantization_level: String?
            }

            let name: String
            let size: Int64?
            let size_vram: Int64?
            let context_length: Int?
            let expires_at: String?
            let details: Details?
        }
        let models: [Model]
    }

    static func parse(_ data: Data) throws -> LocalRuntimeReading {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OllamaError.invalidResponse
        }
        var seen = Set<String>()
        let models = try response.models.map { model in
            guard !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(model.name).inserted,
                  model.size.map({ $0 >= 0 }) ?? true,
                  model.size_vram.map({ $0 >= 0 }) ?? true,
                  model.context_length.map({ $0 > 0 }) ?? true else {
                throw OllamaError.invalidResponse
            }
            let quantization = model.details?.quantization_level?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalRuntimeReading.Model(
                name: model.name, memoryBytes: model.size, contextLength: model.context_length,
                quantizationLevel: quantization?.isEmpty == false ? quantization : nil,
                gpuMemoryBytes: model.size_vram, expiresAt: model.expires_at.flatMap(parseISO8601)
            )
        }.sorted { $0.id < $1.id }
        return LocalRuntimeReading(models: models)
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            struct Details: Decodable {
                let quantization_level: String?
                let context_length: Int?
            }

            let name: String
            let size: Int64?
            let modified_at: String?
            let details: Details?
        }
        let models: [Model]
    }

    /// The installed model touched most recently, from `/api/tags`, shown as
    /// not loaded so an idle server still has a cell to hover. Its byte count
    /// is the size on disk, labelled as such. Nil when nothing is installed or
    /// the listing cannot be read: the idle summary then stands as before.
    static func parseInstalled(_ data: Data) -> LocalRuntimeReading.Model? {
        guard let response = try? JSONDecoder().decode(TagsResponse.self, from: data) else { return nil }
        let candidates = response.models.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ($0.size.map { $0 >= 0 } ?? true)
        }
        let newest = candidates.max { lhs, rhs in
            let l = lhs.modified_at.flatMap(parseISO8601) ?? .distantPast
            let r = rhs.modified_at.flatMap(parseISO8601) ?? .distantPast
            return l == r ? lhs.name > rhs.name : l < r
        }
        guard let model = newest else { return nil }
        let quantization = model.details?.quantization_level?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalRuntimeReading.Model(
            name: model.name, memoryBytes: model.size,
            contextLength: model.details?.context_length.flatMap { $0 > 0 ? $0 : nil },
            quantizationLevel: quantization?.isEmpty == false ? quantization : nil,
            memoryKind: .modelSize, loaded: false)
    }

    static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

enum OllamaError: LocalizedError {
    case invalidEndpoint
    case unavailable
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Use an HTTP address on this Mac, such as http://127.0.0.1:11434."
        case .unavailable:
            return "Ollama server unavailable. Open Ollama and check the server address."
        case .invalidResponse:
            return "This server did not return an Ollama model listing."
        case .http(let code):
            return "Ollama returned HTTP \(code). Check the server address and configuration."
        }
    }
}

enum OllamaEndpoint {
    static let defaultAddress = "http://127.0.0.1:11434"

    static func parse(_ address: String) throws -> URL {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "http",
              let host = parts.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw OllamaError.invalidEndpoint
        }
        // Resolve the familiar spelling to a literal loopback address; no DNS or
        // proxy is needed for the local-only connection.
        parts.host = host == "localhost" ? "127.0.0.1" : host
        parts.scheme = "http"
        parts.path = ""
        guard let url = parts.url else { throw OllamaError.invalidEndpoint }
        return url
    }
}
