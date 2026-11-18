import SwiftUI

/// One schedule (docs/scheduler.md): what the agent is asked, when, where results go; Run Now,
/// Pause/Resume, Edit, Delete; and its history, each run readable.
struct ScheduleDetailView: View {
    @ObservedObject var gateway: GatewayClient
    @State var job: ScheduleJob
    @Environment(\.dismiss) private var dismiss

    @State private var runs: [ScheduleRun]?
    @State private var next: [Date] = []
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var working = false
    @State private var problem: String?
    @State private var notice: String?

    private var agentName: String {
        gateway.profiles.first { $0.profile_id == job.profile_id }?.name ?? job.profile_id
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: LK.Spacing.xs) {
                    Text(job.title).font(LK.Typography.title)
                    if job.isPaused {
                        HStack(spacing: LK.Spacing.xxs) {
                            Image(systemName: "pause.circle")
                            Text("Paused")
                        }
                        .font(LK.Typography.captionStrong)
                        .foregroundStyle(.secondary)
                    }
                }
                .listRowSeparator(.hidden, edges: .bottom)
                LabeledContent("Agent", value: agentName)
                LabeledContent("When", value: ScheduleWords.describe(job.schedule))
                if !job.isPaused, job.state != "completed", !next.isEmpty {
                    LabeledContent("Next") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(next, id: \.self) { date in
                                Text(date <= .now.addingTimeInterval(30) ? "Due now" : ScheduleWords.moment(date))
                            }
                        }
                    }
                }
                LabeledContent("Results go to", value: ScheduleWords.destination(job.deliver))
                if let times = job.repeat.times {
                    LabeledContent("Runs", value: "\(job.repeat.completed) of \(times)")
                }
                if let model = job.model { LabeledContent("Model", value: model) }
                if !job.skills.isEmpty { LabeledContent("Skills", value: job.skills.joined(separator: ", ")) }
            }
            Section("What the Agent Is Asked") {
                Text(job.prompt.isEmpty ? (job.script ? "Runs a script on the instance." : "Nothing") : job.prompt)
                    .font(LK.Typography.callout)
                    .textSelection(.enabled)
            }
            if let error = job.last_error {
                Section("Last Problem") {
                    Text(error).font(LK.Typography.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section {
                let cantRun = working || job.isPaused || job.state == "completed"
                Button("Run Now", systemImage: "play.circle") { act("run") }
                    .disabled(cantRun)
                    .opacity(cantRun ? 0.45 : 1)
                if job.isPaused {
                    Button("Resume", systemImage: "play") { act("resume") }.disabled(working)
                } else {
                    Button("Pause", systemImage: "pause") { act("pause") }.disabled(working || job.state == "completed")
                }
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete Cron Job", systemImage: "trash").foregroundStyle(.red)
                }
                .disabled(working)
                .confirmationDialog("Delete this cron job?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { delete() }
                } message: {
                    Text("Hermes stops running it. Results it already sent stay where they are.")
                }
            } footer: {
                if let notice { Text(notice) }
            }
            Section("History") {
                if let runs {
                    if runs.isEmpty {
                        Text("It hasn't run yet.").font(LK.Typography.callout).foregroundStyle(.secondary)
                    }
                    ForEach(runs) { run in
                        NavigationLink {
                            ScheduleRunView(gateway: gateway, job: job, run: run)
                        } label: {
                            runRow(run)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(job.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editing = true }.disabled(job.script && job.prompt.isEmpty)
            }
        }
        .sheet(isPresented: $editing) {
            ScheduleEditorView(gateway: gateway, job: job, profileId: job.profile_id) { saved in job = saved }
        }
        .alert("Couldn't Do That", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .task(id: job) { await loadNext() }
        .task { await loadRuns() }
        .task(id: gateway.schedulesChanges) {
            guard runs != nil, gateway.lastSchedulesChange == nil || gateway.lastSchedulesChange == job.profile_id else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await reload()
        }
        .refreshable { await reload() }
    }

    private func runRow(_ run: ScheduleRun) -> some View {
        HStack(spacing: LK.Spacing.sm) {
            Image(systemName: run.status == "failed" ? "exclamationmark.triangle.fill"
                  : run.status == "running" ? "bolt.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(run.status == "failed" ? LK.Palette.danger : run.status == "running" ? LK.Palette.accent : LK.Palette.success)
            VStack(alignment: .leading, spacing: 2) {
                if let start = run.started_at {
                    Text(ScheduleWords.moment(Date(timeIntervalSince1970: start)))
                        .font(LK.Typography.callout)
                }
                Text(run.status == "running" ? "Running now" : run.status == "failed" ? "Failed" : runLength(run))
                    .font(LK.Typography.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func runLength(_ run: ScheduleRun) -> String {
        guard let start = run.started_at, let end = run.ended_at, end > start else { return "Done" }
        return "Done in " + KanbanBoard.duration(end - start)
    }

    private func act(_ action: String) {
        working = true
        Task {
            defer { working = false }
            do {
                job = try await gateway.scheduleAction(action, job.id, for: job.profile_id)
                notice = action == "run" ? "It runs within a minute; the result comes to \(ScheduleWords.destination(job.deliver))." : nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func delete() {
        working = true
        Task {
            defer { working = false }
            do {
                try await gateway.deleteSchedule(job.id, for: job.profile_id)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func reload() async {
        if let fresh = try? await gateway.schedules(for: job.profile_id).first(where: { $0.id == job.id }) {
            job = fresh
        }
        await loadRuns()
    }

    private func loadRuns() async {
        runs = (try? await gateway.scheduleRuns(job.id, for: job.profile_id)) ?? runs ?? []
    }

    /// The next times, as Hermes reckons them.
    private func loadNext() async {
        let first = job.next_run_at.flatMap(ScheduleWords.date(from:))
        var preview: [Date] = []
        if job.schedule.kind == "cron" {
            preview = ((try? await gateway.previewSchedule(ScheduleWords.text(for: job.schedule)))?.next ?? [])
                .compactMap(ScheduleWords.date(from:))
        }
        next = ScheduleWords.nextTimes(job.schedule, first: first, preview: preview)
    }
}

/// What one run produced.
struct ScheduleRunView: View {
    @ObservedObject var gateway: GatewayClient
    let job: ScheduleJob
    let run: ScheduleRun
    @State private var text: String?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LK.Spacing.md) {
                if let text {
                    if text.isEmpty {
                        Text("Nothing was kept from this run.").foregroundStyle(.secondary)
                    } else {
                        Text(LocalizedStringKey(text)).textSelection(.enabled)
                    }
                } else if let failure {
                    LKNotice(.warning, failure)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(LK.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(run.started_at.map { Date(timeIntervalSince1970: $0).formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "Run")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let text, !text.isEmpty {
                ToolbarItem(placement: .primaryAction) { ShareLink(item: text) }
            }
        }
        .task {
            do {
                text = try await gateway.scheduleOutput(job.id, run: run.id, for: job.profile_id)
            } catch {
                failure = "Couldn't load it: \(error.localizedDescription)"
            }
        }
    }
}
