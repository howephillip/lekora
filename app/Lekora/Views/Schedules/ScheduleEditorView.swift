import SwiftUI

/// A new schedule, or editing one (docs/scheduler.md): what to do; when, with simple pickers or in
/// plain words (Hermes says what it understood and when it will run); and an Advanced section.
struct ScheduleEditorView: View {
    enum Mode: String { case pick, words }
    enum Kind: String, CaseIterable, Identifiable {
        case every = "At an Interval", daily = "Every Day", weekdays = "Weekdays", days = "Chosen Days", monthly = "Monthly", once = "Once"
        var id: String { rawValue }
    }

    @ObservedObject var gateway: GatewayClient
    /// nil: a new schedule.
    let job: ScheduleJob?
    /// The agent it's for (nil: chosen here).
    let profileId: String?
    let saved: (ScheduleJob) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var agent = ""
    @State private var name = ""
    @State private var prompt = ""
    @State private var mode = Mode.pick
    @State private var kind = Kind.daily
    @State private var everyCount = 1
    @State private var everyHours = true
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    @State private var days: Set<Int> = [1]
    @State private var monthDay = 1
    @State private var onceAt = Date.now.addingTimeInterval(3600)
    @State private var words = ""
    @State private var cron = ""
    @State private var limited = false
    @State private var times = 1
    @State private var deliver = "lekora"
    @State private var model = ""
    @State private var skills = ""
    @State private var preview: SchedulePreview?
    @State private var previewProblem: String?
    @State private var saving = false
    @State private var problem: String?
    @State private var loaded = false

    private var isNew: Bool { job == nil }

    var body: some View {
        NavigationStack {
            Form {
                if isNew && profileId == nil {
                    Picker("Agent", selection: $agent) {
                        ForEach(gateway.profiles) { Text($0.name).tag($0.profile_id) }
                    }
                }
                Section {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(3...10)
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text("For example: “Summarise my unread email and tell me what needs a reply.”")
                }
                Section {
                    Picker("When", selection: $mode) {
                        Text("Pick").tag(Mode.pick)
                        Text("In Words").tag(Mode.words)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!cron.isEmpty)
                    if mode == .pick { pickers } else {
                        TextField("e.g. every 2h, weekdays at 9am, in 30m", text: $words)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("When")
                } footer: {
                    previewLine
                }
                Section {
                    DisclosureGroup("Advanced") {
                        LabeledContent("Cron") {
                            TextField("Cron", text: $cron, prompt: Text("0 9 * * 1-5"))
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(LK.Typography.code)
                        }
                        Toggle("Run a set number of times", isOn: $limited)
                        if limited {
                            Stepper("\(times) time\(times == 1 ? "" : "s")", value: $times, in: 1...1000)
                        }
                        Picker("Results go to", selection: $deliver) {
                            Text("Lekora chat").tag("lekora")
                            Text("Kept on the instance").tag("local")
                            if let current = job?.deliver, !current.hasPrefix("lekora"), current != "local" {
                                Text(ScheduleWords.destination(current)).tag(current)
                            }
                        }
                        LabeledContent("Model") {
                            TextField("Model", text: $model, prompt: Text("The agent's own"))
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        LabeledContent("Skills") {
                            TextField("Skills", text: $skills, prompt: Text("e.g. news, email"))
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                } footer: {
                    if !cron.isEmpty { Text("The cron expression is used instead of the choice above.") }
                }
                if let problem {
                    Section { LKNotice(.warning, problem) }
                }
            }
            .navigationTitle(isNew ? "New Schedule" : "Edit Schedule")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { save() }.disabled(!canSave)
                }
            }
            .onAppear(perform: fill)
            .task(id: scheduleText) {
                // What Hermes understands, a moment after the choice settles.
                let text = scheduleText
                guard !text.isEmpty else { preview = nil; previewProblem = nil; return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                do {
                    preview = try await gateway.previewSchedule(text)
                    previewProblem = nil
                } catch let error as HostError where error.code == "INVALID_SCHEDULE" {
                    preview = nil
                    previewProblem = "Hermes didn't understand that. Try: every 2h, weekdays at 9am, every monday 8am, in 30m, or a cron expression like 0 9 * * 1-5."
                } catch {
                    preview = nil
                    previewProblem = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Pickers

    @ViewBuilder
    private var pickers: some View {
        Picker("Repeats", selection: $kind) {
            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
        }
        switch kind {
        case .every:
            Stepper(value: $everyCount, in: 1...(everyHours ? 168 : 59)) {
                Text("Every \(everyCount) \(everyHours ? (everyCount == 1 ? "hour" : "hours") : "minutes")")
            }
            Picker("Unit", selection: $everyHours) {
                Text("Minutes").tag(false)
                Text("Hours").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: everyHours) { _, hours in
                everyCount = min(everyCount, hours ? 168 : 59)
            }
        case .daily, .weekdays:
            DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
        case .days:
            HStack(spacing: LK.Spacing.xs) {
                ForEach(dayOrder, id: \.self) { day in
                    let on = days.contains(day)
                    Button {
                        if on { days.remove(day) } else { days.insert(day) }
                    } label: {
                        Text(Calendar.current.veryShortWeekdaySymbols[day])
                            .font(LK.Typography.callout.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(on ? AnyShapeStyle(LK.Palette.accent) : LK.Surface.inset, in: Circle())
                            .foregroundStyle(on ? LK.Palette.onAccent : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[day])
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
            DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
        case .monthly:
            Picker("On the", selection: $monthDay) {
                ForEach(1...28, id: \.self) { Text(ScheduleWords.ordinal($0, locale: .current)).tag($0) }
            }
            DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
        case .once:
            DatePicker("At", selection: $onceAt, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
        }
    }

    /// The week as this phone starts it.
    private var dayOrder: [Int] {
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { (first + $0) % 7 }
    }

    private var choice: ScheduleWords.Choice {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let h = c.hour ?? 9, m = c.minute ?? 0
        switch kind {
        case .every: return .every(minutes: everyCount * (everyHours ? 60 : 1))
        case .daily: return .daily(hour: h, minute: m)
        case .weekdays: return .weekdays(hour: h, minute: m)
        case .days: return .days(days, hour: h, minute: m)
        case .monthly: return .monthly(day: monthDay, hour: h, minute: m)
        case .once: return .once(onceAt)
        }
    }

    /// What Hermes is given.
    private var scheduleText: String {
        let expr = cron.trimmingCharacters(in: .whitespaces)
        if !expr.isEmpty { return expr }
        if mode == .words { return words.trimmingCharacters(in: .whitespaces) }
        if kind == .days && days.isEmpty { return "" }
        return choice.hermesSchedule()
    }

    @ViewBuilder
    private var previewLine: some View {
        if let previewProblem {
            Text(previewProblem).foregroundStyle(LK.Palette.danger)
        } else if let preview {
            let when = cron.isEmpty && mode == .pick ? ScheduleWords.describe(choice) : ScheduleWords.describe(preview.when)
            let upcoming = preview.next.compactMap(ScheduleWords.date(from:)).map { ScheduleWords.moment($0) }
            if preview.kind == "once" {
                Text(when.hasPrefix("Once") ? "\(when)." : "Once, \(upcoming.first ?? when).")
            } else {
                Text("\(when). Next: \(upcoming.isEmpty ? "not again" : upcoming.joined(separator: "; ")).")
            }
        } else if kind == .days && mode == .pick && cron.isEmpty && days.isEmpty {
            Text("Choose at least one day.")
        }
    }

    private var canSave: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !scheduleText.isEmpty
            && previewProblem == nil && !saving && (!agent.isEmpty || profileId != nil || job != nil)
    }

    // MARK: - Saving

    private func fill() {
        guard !loaded else { return }
        loaded = true
        agent = profileId ?? gateway.profiles.first?.profile_id ?? ""
        guard let job else { return }
        name = job.name ?? ""
        prompt = job.prompt
        deliver = job.deliver.hasPrefix("lekora") ? "lekora" : job.deliver
        model = job.model ?? ""
        skills = job.skills.joined(separator: ", ")
        if let t = job.repeat.times, job.schedule.kind != "once" { limited = true; times = t }
        switch ScheduleWords.choice(for: job.schedule) {
        case .every(let minutes)?:
            kind = .every
            everyHours = minutes % 60 == 0
            everyCount = everyHours ? minutes / 60 : minutes
        case .daily(let h, let m)?: kind = .daily; setTime(h, m)
        case .weekdays(let h, let m)?: kind = .weekdays; setTime(h, m)
        case .days(let d, let h, let m)?: kind = .days; days = d; setTime(h, m)
        case .monthly(let day, let h, let m)?: kind = .monthly; monthDay = min(day, 28); setTime(h, m)
        case .once(let date)?: kind = .once; onceAt = date
        case nil:
            mode = .words
            words = ScheduleWords.text(for: job.schedule)
        }
    }

    private func setTime(_ h: Int, _ m: Int) {
        time = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: .now) ?? time
    }

    private var skillList: [String] {
        skills.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() {
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespaces)
        let schedule = scheduleText
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                let result: ScheduleJob
                if let job {
                    var changes = ScheduleChanges()
                    if cleanName != (job.name ?? "") { changes.name = cleanName }
                    if cleanPrompt != job.prompt { changes.prompt = cleanPrompt }
                    if schedule != ScheduleWords.text(for: job.schedule) { changes.schedule = schedule }
                    let oldDeliver = job.deliver.hasPrefix("lekora") ? "lekora" : job.deliver
                    if deliver != oldDeliver { changes.deliver = deliver }
                    let newTimes: Int? = limited ? times : nil
                    if job.schedule.kind != "once" && newTimes != job.repeat.times { changes.repeatTimes = .some(newTimes) }
                    if cleanModel != (job.model ?? "") { changes.model = .some(cleanModel.isEmpty ? nil : cleanModel) }
                    if skillList != job.skills { changes.skills = skillList }
                    result = changes.isEmpty ? job : try await gateway.updateSchedule(job.id, changes, for: job.profile_id)
                } else {
                    let data = ScheduleCreateData(name: cleanName.isEmpty ? nil : cleanName, prompt: cleanPrompt, schedule: schedule,
                                                  deliver: deliver, repeat: limited ? times : nil,
                                                  model: cleanModel.isEmpty ? nil : cleanModel,
                                                  skills: skillList.isEmpty ? nil : skillList)
                    result = try await gateway.createSchedule(data, for: profileId ?? agent)
                }
                saved(result)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
