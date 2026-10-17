import Foundation

/// All providers recorded by OpenCode; independent of the OpenCode Go quota.
actor OpenCodeAllProvider: UsageProvider {
    nonisolated let id = "opencode-all"
    nonisolated let displayName = "OpenCode All"
    nonisolated let glyph = ProviderGlyph.opencode
    private let database: URL

    init(database: URL = OpenCodeNVIDIAUsage.database) {
        self.database = database
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance("Use OpenCode locally to record token usage.")
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let now = Date()
        guard let usage = OpenCodeNVIDIAUsage.read(database: database, now: now, providerID: nil) else {
            throw UsageProviderError.nothingMetered("OpenCode has no readable local usage database.")
        }
        return Self.snapshot(usage: usage, now: now)
    }

    static func snapshot(usage: NVIDIANIMTokenUsage, now: Date = Date()) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(
            id: "opencode-all", displayName: "OpenCode All", glyph: .opencode,
            fidelity: .derived, status: .ok,
            windows: [
                LimitWindow(id: "total", label: L10n.t("Total tokens recorded"), used: usage.tokensTotal,
                    detail: usage.tokensTotal.formatted(.number.locale(L10n.locale))),
                LimitWindow(id: "month", label: L10n.t("Tokens this month"), used: usage.tokensThisMonth,
                    detail: usage.tokensThisMonth.formatted(.number.locale(L10n.locale))),
                LimitWindow(id: "today", label: L10n.t("Tokens today"), used: usage.tokensToday,
                    detail: usage.tokensToday.formatted(.number.locale(L10n.locale))),
                LimitWindow(id: "calls", label: L10n.t("Calls this month"), used: usage.callsThisMonth,
                    detail: usage.callsThisMonth.formatted(.number.locale(L10n.locale)))
            ], headlineID: "total"
        )
        snapshot.dailyTokenUsage = usage.last30Days(now: now)
        return snapshot
    }
}
