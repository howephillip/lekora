import Charts
import SwiftUI

/// Usage and spend across every agent, from Hermes, with what each provider itself reports
/// (docs/analytics.md).
struct AnalyticsView: View {
    @ObservedObject var gateway: GatewayClient
    /// One agent's numbers (opened from the by-agent list); nil = every agent.
    var profileId: String?

    @State private var days = 7
    @State private var report: AnalyticsReport?
    @State private var loading = false
    @State private var failure: String?
    @State private var pickedDay: String?

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $days) {
                    Text("Today").tag(1)
                    Text("7 Days").tag(7)
                    Text("30 Days").tag(30)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let report {
                headline(report)
                if report.days > 1 { chart(report) }
                if profileId == nil, !report.by_agent.isEmpty {
                    breakdown("By Agent", rows: report.by_agent.map { ($0.profile_id, gateway.agentName($0.profile_id), $0.cost_usd, $0.tokens) },
                              link: true)
                }
                if !report.by_source.isEmpty {
                    breakdown("By Where", rows: report.by_source.map { ($0.source, LKAnalyticsText.source($0.source), $0.cost_usd, $0.tokens) })
                }
                if !report.by_model.isEmpty {
                    breakdown("By Model", rows: report.by_model.map { ($0.model, $0.model.components(separatedBy: "/").last ?? $0.model, $0.cost_usd, $0.tokens) })
                }
                accounts(report)
            } else if let failure {
                Section { Text(failure).foregroundStyle(LK.Palette.danger) }
            } else {
                Section { HStack { ProgressView(); Text("Asking Hermes…").foregroundStyle(.secondary) } }
            }
        }
        .navigationTitle(profileId.map(gateway.agentName) ?? "Analytics")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        // Again once connected, when the screen opened while the instance was still connecting.
        .task(id: "\(days)|\(isConnected)") { if isConnected || report == nil { await load() } }
        .onChange(of: days) { _, _ in pickedDay = nil }
        .overlay(alignment: .top) {
            if loading && report != nil { ProgressView().padding(.top, LK.Spacing.sm) }
        }
    }

    private var isConnected: Bool {
        if case .connected = gateway.state { return true }
        return false
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            report = try await gateway.analytics(days: days, profileId: profileId)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Headline

    private func headline(_ report: AnalyticsReport) -> some View {
        Section {
            VStack(alignment: .leading, spacing: LK.Spacing.xs) {
                Text(LKAnalyticsText.money(report.totals.cost_usd))
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .accessibilityLabel("Estimated spend \(LKAnalyticsText.money(report.totals.cost_usd))")
                Text("\(LKUsageText.short(report.totals.tokens)) tokens · \(report.totals.sessions) \(report.totals.sessions == 1 ? "conversation" : "conversations")")
                    .font(LK.Typography.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, LK.Spacing.xs)
        } header: {
            Text(LKAnalyticsText.period(report.days))
        } footer: {
            Text("Hermes' estimate, from token counts and price lists. Your providers' own figures are under Accounts.")
        }
    }

    // MARK: - Daily chart (one series: spend per day; tap a day to read it)

    private func chart(_ report: AnalyticsReport) -> some View {
        let picked = report.daily.first { $0.day == pickedDay }
        return Section {
            Chart(report.daily) { day in
                BarMark(x: .value("Day", day.date ?? .now, unit: .day),
                        y: .value("Spend", day.cost_usd), width: .ratio(0.6))
                    .foregroundStyle(LK.Palette.accent.opacity(pickedDay == nil || pickedDay == day.day ? 1 : 0.35))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            }
            // A tap or a drag picks the day under the finger; it stays picked after release.
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { touch in
                            guard let frame = proxy.plotFrame else { return }
                            let x = touch.location.x - geo[frame].origin.x
                            guard let date: Date = proxy.value(atX: x),
                                  let day = report.daily.first(where: { Calendar.current.isDate($0.date ?? .distantPast, inSameDayAs: date) })
                            else { return }
                            pickedDay = day.day
                        })
                }
            }
            .chartYScale(domain: 0...max((report.daily.map(\.cost_usd).max() ?? 0) * 1.15, 0.01))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let v = value.as(Double.self) { Text(LKAnalyticsText.money(v, short: true)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: report.days > 7 ? 7 : 1)) { _ in
                    AxisValueLabel(format: report.days > 7 ? .dateTime.month(.abbreviated).day() : .dateTime.weekday(.abbreviated))
                }
            }
            .frame(height: 170)
            .accessibilityLabel("Spend per day")
            .accessibilityValue(report.daily.map { "\($0.day): \(LKAnalyticsText.money($0.cost_usd))" }.joined(separator: ", "))
        } header: {
            Text("Spend per Day")
        } footer: {
            if let picked {
                Text("\(picked.date.map { $0.formatted(.dateTime.weekday(.wide).month().day()) } ?? picked.day): \(LKAnalyticsText.money(picked.cost_usd)) · \(LKUsageText.short(picked.tokens)) tokens")
                    .monospacedDigit()
            } else {
                Text("Touch the chart to read a day.")
            }
        }
    }

    // MARK: - Breakdowns: a ranked list, each with its value and a thin bar

    private func breakdown(_ title: String, rows: [(id: String, name: String, cost: Double, tokens: Int)], link: Bool = false) -> some View {
        let top = max(rows.map(\.cost).max() ?? 0, 0.000_001)
        return Section(title) {
            ForEach(rows.prefix(12), id: \.id) { row in
                let content = LKAnalyticsRow(name: row.name, value: LKAnalyticsText.money(row.cost),
                                             detail: "\(LKUsageText.short(row.tokens)) tokens", fraction: row.cost / top,
                                             avatar: link ? row.id : nil, palette: gateway.avatarPalettes[row.id])
                if link {
                    NavigationLink { AnalyticsView(gateway: gateway, profileId: row.id) } label: { content }
                } else {
                    content
                }
            }
        }
    }

    // MARK: - Accounts: what each provider reports

    @ViewBuilder
    private func accounts(_ report: AnalyticsReport) -> some View {
        Section {
            if report.accounts.isEmpty {
                Text("No provider reported account figures to Hermes.").foregroundStyle(.secondary)
            }
            ForEach(report.accounts) { account in
                VStack(alignment: .leading, spacing: LK.Spacing.xs) {
                    HStack {
                        Text(LKAnalyticsText.provider(account.provider)).font(LK.Typography.headline)
                        if let plan = account.plan { Text(plan).font(LK.Typography.caption).foregroundStyle(.secondary) }
                    }
                    if let reason = account.unavailable_reason {
                        Text(reason).font(LK.Typography.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(account.windows ?? [], id: \.self) { window in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.label).font(LK.Typography.subheadline)
                            if let used = window.used_percent {
                                HStack(spacing: LK.Spacing.sm) {
                                    ProgressView(value: min(max(used, 0), 100), total: 100)
                                        .tint(used >= 90 ? LK.Palette.warning : LK.Palette.accent)
                                    Text("\(Int(used.rounded()))% used")
                                        .font(LK.Typography.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if let detail = window.detail {
                                Text(detail).font(LK.Typography.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    ForEach(account.details ?? [], id: \.self) { line in
                        Text(line).font(LK.Typography.footnote).monospacedDigit()
                    }
                    if let agents = account.agents, !agents.isEmpty, gateway.profiles.count > 1 {
                        Text("Used by " + agents.map(gateway.agentName).joined(separator: ", "))
                            .font(LK.Typography.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, LK.Spacing.xs)
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("As your providers report them to Hermes, right now (not just this period).")
        }
    }
}

/// One line of a breakdown: name, value, a detail line and a thin bar for its share.
struct LKAnalyticsRow: View {
    let name: String
    let value: String
    let detail: String
    let fraction: Double
    var avatar: String?
    var palette: Int?

    var body: some View {
        HStack(spacing: LK.Spacing.md) {
            if let avatar { LKAgentAvatar(id: avatar, palette: palette, size: 28) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).lineLimit(1)
                    Spacer()
                    Text(value).monospacedDigit().foregroundStyle(.primary)
                }
                GeometryReader { geo in
                    Capsule().fill(LK.Palette.accent)
                        .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)), height: 4)
                }
                .frame(height: 4)
                .accessibilityHidden(true)
                Text(detail).font(LK.Typography.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Analytics in words.
enum LKAnalyticsText {
    static func money(_ usd: Double, short: Bool = false) -> String {
        if usd == 0 { return "$0" }
        if usd < 0.01 { return "<$0.01" }
        if short && usd >= 100 { return String(format: "$%.0f", usd) }
        return String(format: "$%.2f", usd)
    }

    static func period(_ days: Int) -> String {
        days == 1 ? "Today" : "Last \(days) Days"
    }

    /// Hermes' platform names as the user reads them.
    static func source(_ source: String) -> String {
        switch source {
        case "lekora": return "Lekora chats"
        case "background": return "Background tasks"
        case "cron": return "Scheduled jobs"
        case "subagent": return "Helpers (sub-agents)"
        case "kanban": return "Board workers"
        case "cli": return "Terminal"
        case "local", "tui": return "Hermes app"
        case "oneshot": return "One-off runs"
        case "api_server": return "API"
        default: return source.prefix(1).uppercased() + source.dropFirst()
        }
    }

    static func provider(_ slug: String) -> String {
        switch slug {
        case "openrouter": return "OpenRouter"
        case "nous": return "Nous Portal"
        case "anthropic": return "Claude"
        case "openai-codex": return "OpenAI Codex"
        case "openai": return "OpenAI"
        case "gemini", "google": return "Google"
        default: return slug.prefix(1).uppercased() + slug.dropFirst()
        }
    }
}
