import Foundation

enum NVIDIANIMCredentials {
    static let environmentKey = "NVIDIA_API_KEY"
    static let monthlyBudgetKey = "NVIDIA_NIM_MONTHLY_TOKEN_BUDGET"

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
                  let token = shellValue(named: environmentKey, in: text)
            else { continue }
            return Credential(token: token, source: "~/\(file)")
        }
        return nil
    }

    static func monthlyTokenBudget(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Int? {
        if let budget = budget(environment[monthlyBudgetKey]) { return budget }
        for file in [".zshrc", ".zprofile", ".profile"] {
            let url = home.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let value = shellValue(named: monthlyBudgetKey, in: text),
                  let budget = budget(value)
            else { continue }
            return budget
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

    private static func budget(_ value: String?) -> Int? {
        nonEmpty(value).flatMap { Int($0.replacingOccurrences(of: "_", with: "")) }.flatMap {
            $0 > 0 ? $0 : nil
        }
    }

    private static func shellValue(named name: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("export ") {
                text.removeFirst("export ".count)
                text = text.trimmingCharacters(in: .whitespaces)
            }
            guard text.hasPrefix("\(name)=") else { continue }
            let value = String(text.dropFirst(name.count + 1))
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
