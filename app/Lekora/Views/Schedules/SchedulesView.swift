import SwiftUI

/// Schedules (docs/scheduler.md): what agents do on their own, as Hermes' cron jobs. Every agent's,
/// grouped by agent, or one agent's (from its Chat Settings).
struct SchedulesView: View {
    @ObservedObject var gateway: GatewayClient
    /// nil: every agent's.
    var profileId: String?

    @State private var jobs: [ScheduleJob]?
    @State private var failure: String?
    @State private var creating = false
    @State private var problem: String?
    @State private var notice: String?

    private var connected: Bool {
        if case .connected = gateway.state { return true }
        return false
    }

    /// The agents shown: this one, or every agent with schedules (in the instance's order).
    private var groups: [(profile: ProfileData, jobs: [ScheduleJob])] {
        let all = jobs ?? []
        return gateway.profiles.compactMap { profile in
            let mine = all.filter { $0.profile_id == profile.profile_id }
                .sorted { ($0.isPaused ? 1 : 0, $0.title.lowercased()) < ($1.isPaused ? 1 : 0, $1.title.lowercased()) }
            return mine.isEmpty ? nil : (profile, mine)
        }
    }

    var body: some View {
        content
            .navigationTitle("Cron Jobs")
            .navigationSubtitle(profileId.flatMap { id in gateway.profiles.first { $0.profile_id == id }?.name }
                                ?? gateway.savedHost?.instanceName ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New Cron Job", systemImage: "plus") }
                        .disabled(!connected || gateway.profiles.isEmpty || jobs == nil)
                }
            }
            .sheet(isPresented: $creating) {
                ScheduleEditorView(gateway: gateway, job: nil, profileId: profileId) { _ in Task { await load() } }
            }
            .task(id: connected) { await load() }
            .task(id: gateway.schedulesChanges) {
                guard jobs != nil else { return }
                if let profileId, let changed = gateway.lastSchedulesChange, changed != profileId { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await load()
            }
            .refreshable { await load() }
            .alert("Couldn't Do That", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice)
                        .font(LK.Typography.callout)
                        .padding(.horizontal, LK.Spacing.lg)
                        .padding(.vertical, LK.Spacing.sm)
                        .foregroundStyle(LK.Palette.onAccent)
                        .background(LK.Palette.accent, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                        .padding(.bottom, LK.Spacing.lg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: notice)
    }

    private func delete(_ job: ScheduleJob) {
        jobs?.removeAll { $0.id == job.id }
        Task {
            do {
                try await gateway.deleteSchedule(job.id, for: job.profile_id)
            } catch {
                problem = error.localizedDescription
                await load()  // it's still there: show it again
            }
        }
    }

    private func run(_ job: ScheduleJob) {
        Task {
            do {
                let due = try await gateway.scheduleAction("run", job.id, for: job.profile_id)
                if let index = jobs?.firstIndex(where: { $0.id == due.id }) { jobs?[index] = due }
                notice = "“\(job.title)” runs within a minute"
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                notice = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let jobs {
            if jobs.isEmpty {
                ContentUnavailableView {
                    Label("No Cron Jobs Yet", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Ask an agent to do something on a schedule, like a morning summary or a weekly check-in. The result comes to its chat.")
                } actions: {
                    Button("New Cron Job") { creating = true }.disabled(!connected)
                }
            } else {
                List {
                    ForEach(groups, id: \.profile.profile_id) { group in
                        Section {
                            ForEach(group.jobs) { job in
                                NavigationLink {
                                    ScheduleDetailView(gateway: gateway, job: job)
                                } label: {
                                    ScheduleRow(job: job)
                                }
                                // Like Messages: swipe left for Delete and Run Now; all the way deletes.
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { delete(job) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    if !job.isPaused && job.state != "completed" {
                                        Button { run(job) } label: {
                                            Label("Run Now", systemImage: "play.fill")
                                        }
                                        .tint(LK.Palette.accent)
                                    }
                                }
                            }
                        } header: {
                            if profileId == nil {
                                Text(group.profile.name)
                                    .font(LK.Typography.subheadline.weight(.semibold))
                                    .textCase(nil)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        } else if !connected {
            ContentUnavailableView("Not Connected", systemImage: "wifi.slash",
                                   description: Text("Cron jobs are on \(gateway.savedHost?.instanceName ?? "your Hermes instance"). They show when Lekora can reach it."))
        } else if let failure {
            ContentUnavailableView {
                Label("Couldn't Load Cron Jobs", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure)
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            ProgressView()
        }
    }

    private func load() async {
        guard connected else { return }
        do {
            jobs = try await gateway.schedules(for: profileId)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// A schedule in the list: what, when, and how it's going.
struct ScheduleRow: View {
    let job: ScheduleJob

    var body: some View {
        // Relative times ("Next in 11 hours") stay current while the list is open.
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: LK.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: LK.Spacing.xs) {
                    Text(job.title).font(LK.Typography.body).lineLimit(2)
                    if job.isPaused {
                        Text("Paused")
                            .font(LK.Typography.captionStrong)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, LK.Spacing.xs)
                            .background(LK.Surface.inset, in: Capsule())
                    }
                }
                Text(ScheduleWords.describe(job.schedule))
                    .font(LK.Typography.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: LK.Spacing.sm) {
                    if let status = ScheduleStatus(job, now: context.date) {
                        Label(status.text, systemImage: status.symbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(status.failed ? LK.Palette.danger : .secondary)
                    }
                    if !job.isPaused, job.state != "completed", let next = job.next_run_at.flatMap(ScheduleWords.date(from:)) {
                        Text("Next \(ScheduleWords.upcoming(next, now: context.date))")
                    }
                }
                .font(LK.Typography.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, LK.Spacing.xxs)
        }
        .accessibilityElement(children: .combine)
    }
}

/// How the last run went.
struct ScheduleStatus {
    let text: String
    let symbol: String
    let failed: Bool

    init?(_ job: ScheduleJob, now: Date = .now) {
        if job.state == "completed" {
            (text, symbol, failed) = ("Finished", "checkmark.circle", false)
            return
        }
        guard let status = job.last_status else { return nil }
        let ok = status == "ok" || status == "success" || status == "completed"
        let when = job.last_run_at.flatMap(ScheduleWords.date(from:)).map { " " + $0.formatted(.relative(presentation: .named, unitsStyle: .wide)) } ?? ""
        (text, symbol, failed) = ok ? ("Ran\(when)", "checkmark.circle", false) : ("Failed\(when)", "exclamationmark.triangle", true)
    }
}
