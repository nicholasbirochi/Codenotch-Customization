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
            let details: Details?
        }
        let models: [Model]
    }

    /// Every installed model from `/api/tags`, shown as not loaded so each one
    /// has a cell to hover while the server is idle. The byte count is the
    /// size on disk, labelled as such. Empty when nothing is installed or the
    /// listing cannot be read: the idle summary then stands as before.
    static func parseInstalled(_ data: Data) -> [LocalRuntimeReading.Model] {
        guard let response = try? JSONDecoder().decode(TagsResponse.self, from: data) else { return [] }
        var seen = Set<String>()
        return response.models.compactMap { model -> LocalRuntimeReading.Model? in
            guard !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  model.size.map({ $0 >= 0 }) ?? true,
                  seen.insert(OllamaThinkingStream.modelKey(model.name)).inserted else { return nil }
            let quantization = model.details?.quantization_level?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalRuntimeReading.Model(
                name: model.name, memoryBytes: model.size,
                contextLength: model.details?.context_length.flatMap { $0 > 0 ? $0 : nil },
                quantizationLevel: quantization?.isEmpty == false ? quantization : nil,
                memoryKind: .modelSize, loaded: false)
        }.sorted { $0.id < $1.id }
    }

    /// Loaded models first, then the installed ones not already loaded. A
    /// client may name a model without its implicit `:latest`, so both lists
    /// are compared by the relay's key.
    static func merging(loaded: [LocalRuntimeReading.Model],
                        installed: [LocalRuntimeReading.Model]) -> [LocalRuntimeReading.Model] {
        let keys = Set(loaded.map { OllamaThinkingStream.modelKey($0.name) })
        return loaded + installed.filter { !keys.contains(OllamaThinkingStream.modelKey($0.name)) }
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
