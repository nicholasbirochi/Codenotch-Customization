import Foundation

enum NVIDIANIMCredentials {
    static let environmentKey = "NVIDIA_API_KEY"

    struct Credential: Equatable {
        let token: String
        let source: String
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> Credential? {
        nonEmpty(environment[environmentKey]).map {
            Credential(token: $0, source: environmentKey)
        }
    }

    static func account(environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderAccount? {
        guard load(environment: environment) != nil else { return nil }
        return ProviderAccount(
            label: nil,
            plan: nil,
            source: environmentKey,
            manageURL: URL(string: "https://build.nvidia.com/settings/api-keys")
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}
