import Foundation

enum NVIDIANIMCredentials {
    static let environmentKey = "NVIDIA_API_KEY"

    struct Credential: Equatable {
        let token: String
        let source: String
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Credential? {
        if let token = nonEmpty(environment[environmentKey]) {
            return Credential(token: token, source: environmentKey)
        }
        for file in [".zshrc", ".zprofile", ".profile"] {
            let url = home.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let token = shellValue(in: text)
            else { continue }
            return Credential(token: token, source: "~/\(file)")
        }
        return nil
    }

    static func account(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ProviderAccount? {
        guard let credential = load(environment: environment, home: home) else { return nil }
        return ProviderAccount(
            label: nil,
            plan: nil,
            source: credential.source,
            manageURL: URL(string: "https://build.nvidia.com/settings/api-keys")
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func shellValue(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("export ") {
                text.removeFirst("export ".count)
                text = text.trimmingCharacters(in: .whitespaces)
            }
            guard text.hasPrefix("\(environmentKey)=") else { continue }
            let value = String(text.dropFirst(environmentKey.count + 1))
                .trimmingCharacters(in: .whitespaces)
            if let token = unquoted(value).flatMap(nonEmpty) { return token }
        }
        return nil
    }

    private static func unquoted(_ value: String) -> String? {
        guard value.count >= 2 else { return value }
        if value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
