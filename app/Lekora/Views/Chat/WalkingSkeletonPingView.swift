import SwiftUI
import PhotosUI
import QuickLook

/// A chat with one agent, opened from the agents list (docs/agents-home.md).
public struct WalkingSkeletonPingView: View {
    @ObservedObject public var gateway: GatewayClient
    public let instanceName: String
    /// Name to show until the active agent is known.
    private let fallbackProfileName: String

    private var profileName: String {
        gateway.activeProfile?.name ?? fallbackProfileName
    }

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    @State private var isOnScreen = false
    /// Whether the user is scrolling (dragging or coasting), as opposed to layout or code
    /// moving the list: only the user's scrolling loads older messages.
    @State private var userIsScrolling = false
    /// Set while a page of older messages loads and the list settles: no further loads,
    /// or the next page would start before this one is back in place.
    @State private var pageInFlight = false
    @Environment(\.scenePhase) private var scenePhase
    /// How far the messages are dragged left to show their times (as in Messages).
    @State private var timeReveal: CGFloat = 0
    private static let timeRevealWidth: CGFloat = 72
    @State private var restoredDraft = false
    /// Changed on every send: a fresh text box, so nothing the keyboard was still holding
    /// (an autocorrect or prediction) can write the sent text back into it.
    @State private var composerID = 0
    /// Chat Settings sheet, opened by tapping the agent at the top.
    @State private var showingSettings = false
    // Photos and files (docs/files.md).
    @State private var attachments: [LKPendingAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var takingPhoto = false
    @State private var uploading = false
    @State private var attachmentProblem: String?
    // Voice notes (docs/voice.md).
    @StateObject private var recorder = VoiceRecorder()
    @StateObject private var player = VoicePlayer()
    @State private var loadingVoice: String?
    // Hearing replies (docs/voice.md §2).
    @StateObject private var speaker = ReplySpeaker()
    @State private var loadingSpeech: String?
    /// Only replies that arrive after the chat opened are spoken by themselves.
    @State private var openedAt = Date()
    /// The file shown in Quick Look, and the one being fetched to show.
    @State private var previewURL: URL?
    @State private var openingFile: String?

    /// Agents on your other computers with unread replies (docs/multiple-instances.md).
    private let unreadElsewhere: Int

    /// The computer's name in the header, once there are several (docs/multiple-instances.md).
    private let computerName: String?

    public init(gateway: GatewayClient, instanceName: String, profileName: String, unreadElsewhere: Int = 0,
                computerName: String? = nil) {
        self.gateway = gateway
        self.instanceName = instanceName
        self.fallbackProfileName = profileName
        self.unreadElsewhere = unreadElsewhere
        self.computerName = computerName
    }

    /// How many other agents have unread replies (the count by the back button).
    private var unreadOthers: Int { gateway.otherAgentsWithUnread + unreadElsewhere }

    private var messages: [ChatEntry] {
        gateway.timeline.entries(for: gateway.activeProfileId)
    }

    private var activity: AgentActivity? {
        gateway.agentActivity[gateway.activeProfileId]
    }

    /// Hermes' status phrases start with the verb ("is using browser_exec…"): put the
    /// agent's name in front.
    private var statusText: String? {
        guard let status = activity?.status?.trimmingCharacters(in: .whitespaces), !status.isEmpty else { return nil }
        if status.hasPrefix("is ") || status.hasPrefix("has ") {
            return "\(profileName) \(status)"
        }
        return status
    }

    /// Dots while the agent works. Hidden while its reply is already streaming in,
    /// unless Hermes says what it's doing (e.g. running a tool between messages).
    private var showsTypingIndicator: Bool {
        guard let activity else { return false }
        // Waiting for you to answer a card: the agent isn't working, and a disappearing
        // bubble would shift the card under your finger.
        if messages.last?.card?.isOpen() == true { return false }
        let streaming = messages.last?.status == .streaming
        return !streaming || !(activity.status ?? "").isEmpty
    }

    private var canSend: Bool {
        isConnected && !uploading
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var isConnected: Bool {
        if case .connected = gateway.state { return true }
        return false
    }

    /// Only while not connected: what's happening ("Connecting…"). Connected, the header shows the model.
    private var subtitle: String? {
        if isConnected { return nil }
        return gateway.state == .disconnected ? "Not connected" : "Connecting…"
    }

    public var body: some View {
        messageList
            // Scrolled up into older messages: a small button back to the newest one.
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        isAtBottom = true
                        scrollToBottom(animated: true)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(.trailing, LK.Spacing.lg)
                    .padding(.bottom, LK.Spacing.sm)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("Newest message")
                }
            }
            .animation(.easeOut(duration: 0.2), value: isAtBottom)
            .lkScreenBackground()
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: LK.Spacing.sm) {
                    // Typing "/": this agent's commands, from Hermes (docs/slash-commands.md).
                    let suggestions = LKCommandMatcher.suggestions(
                        for: draft, commands: gateway.commands[gateway.activeProfileId] ?? [])
                    if !suggestions.isEmpty {
                        LKCommandSuggestions(suggestions) { picked in
                            draft = picked.insert
                            inputFocused = true
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if !attachments.isEmpty {
                        LKAttachmentStrip(attachments) { removed in
                            attachments.removeAll { $0.id == removed.id }
                        }
                        .disabled(uploading)
                    }
                    LKComposer("Message \(profileName)", text: $draft, canSend: canSend,
                               focus: $inputFocused, accessory: AnyView(attachMenu),
                               replacement: voiceBar, replacementID: voiceStage,
                               action: showsMic ? AnyView(LKFieldMicButton(action: startRecording)) : nil,
                               onSend: send)
                        .id(composerID)
                        .animation(.spring(duration: 0.42, bounce: 0.22), value: voiceStage)
                        // Haptics: recording started, stopped, and sent or thrown away.
                        .sensoryFeedback(.impact(weight: .medium), trigger: recorder.isRecording) { _, now in now }
                        .sensoryFeedback(.impact(weight: .light), trigger: recorder.draft == nil) { was, _ in !was }
                }
                .animation(.easeOut(duration: 0.15), value: draft.hasPrefix("/"))
            }
            .navigationTitle(profileName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Next to the standard back button (which keeps the swipe-back gestures):
                // how many other agents have unread replies — docs/agents-home.md.
                if unreadOthers > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        unreadBadge
                    }
                }
                // Voice mode, one tap away (docs/voice.md §2).
                ToolbarItem(placement: .primaryAction) {
                    Button(action: toggleVoiceMode) {
                        Image(systemName: voiceMode ? "waveform.circle.fill" : "waveform.circle")
                            .symbolRenderingMode(voiceMode ? .multicolor : .monochrome)
                            .foregroundStyle(voiceMode ? LK.Palette.accent : .primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .sensoryFeedback(.selection, trigger: voiceMode)
                    .disabled(!isConnected)
                    .accessibilityLabel(voiceMode ? "Voice replies on" : "Voice replies off")
                    .accessibilityHint("Replies come as voice notes")
                }
                // Change this agent's model: opens Hermes' own model picker (as /model does).
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await gateway.openModelPicker() }
                    } label: {
                        Label("Model", systemImage: "cpu")
                    }
                    .disabled(!isConnected)
                }
                ToolbarItem(placement: .title) {
                    Button { showingSettings = true } label: {
                        ChatHeaderTitle(gateway: gateway, profileName: profileName, computer: computerName, connection: subtitle,
                                        working: activity != nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens chat settings")
                }
            }
            #endif
            // New messages count as read only while the chat is on screen with the app in front.
            .onAppear {
                isOnScreen = true
                updateVisibility()
                if !restoredDraft {  // once: a later onAppear must not bring back sent text
                    restoredDraft = true
                    draft = gateway.drafts[gateway.activeProfileId] ?? ""
                }
            }
            .onChange(of: draft) { _, text in
                gateway.drafts[gateway.activeProfileId] = text.isEmpty ? nil : text
            }
            // This agent's commands; again once connected, if the chat opened offline.
            .task(id: "\(gateway.activeProfileId)|\(isConnected)") {
                if isConnected {
                    await gateway.loadVoiceSettings(for: gateway.activeProfileId)
                    await gateway.loadSettings(for: gateway.activeProfileId)
                    await gateway.loadCommands(for: gateway.activeProfileId)
                }
            }
            .sheet(isPresented: $showingSettings) {
                ChatSettingsView(gateway: gateway, profileId: gateway.activeProfileId, agentName: profileName)
                    .presentationDetents([.large])
            }
            // Opened by a push: once it has slid in and the message bar is measured, show
            // the newest message in full.
            .task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                isAtBottom = true
                scrollToBottom(animated: false)
            }
            .onDisappear {
                isOnScreen = false
                updateVisibility()
                player.stop()
                recorder.discard()
                speaker.stop()
            }
            .onChange(of: scenePhase) { _, _ in updateVisibility() }
            // Speak replies by themselves, as the agent's settings say (docs/voice.md §2).
            .onChange(of: newestReply) { _, reply in
                if let reply { autoSpeak(reply) }
            }
            // Voice mode: play each spoken part of the newest reply as it arrives.
            .onChange(of: newestLiveParts) { old, live in
                guard let live else { return }
                if live.count != old?.count || live.id != old?.id { playLiveParts(live) }
                if live.done { player.expectsMore = false }
            }
            .photosPicker(isPresented: $choosingPhotos, selection: $photoItems,
                          maxSelectionCount: max(GatewayClient.maxFilesPerMessage - attachments.count, 1),
                          matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task {
                    for (index, item) in items.enumerated() {
                        do { addAttachment(try await AttachmentImport.fromPhotos(item, index: index)) }
                        catch { attachmentProblem = error.localizedDescription }
                    }
                }
            }
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        do { addAttachment(try AttachmentImport.fromFile(url)) }
                        catch { attachmentProblem = error.localizedDescription }
                    }
                case .failure(let error):
                    attachmentProblem = error.localizedDescription
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraPicker { image in
                    do { addAttachment(try AttachmentImport.fromCamera(image)) }
                    catch { attachmentProblem = error.localizedDescription }
                }
                .ignoresSafeArea()
            }
            #endif
            .quickLookPreview($previewURL)
            .alert("Can't attach that", isPresented: Binding(get: { attachmentProblem != nil },
                                                            set: { if !$0 { attachmentProblem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(attachmentProblem ?? "")
            }
    }

    // MARK: - Hearing replies (docs/voice.md §2)

    private var voiceSettings: AgentVoiceSettings {
        gateway.voiceSettings[gateway.activeProfileId] ?? .standard
    }

    private var usesHermesVoice: Bool {
        voiceSettings.engine == "hermes" && gateway.hermesVoice[gateway.activeProfileId]?.available == true
    }

    private func isSpeaking(_ entry: ChatEntry) -> Bool {
        speaker.speakingId == entry.id || (player.currentId == "speech-" + entry.id && player.isPlaying)
    }

    /// The Listen button: the whole reply, or stop.
    private func listen(to entry: ChatEntry) {
        if isSpeaking(entry) {
            speaker.stop()
            player.stop()
            return
        }
        speaker.stop()
        player.stop()
        if usesHermesVoice, let seq = entry.seq {
            playHermesSpeech(entry, seq: seq)
        } else {
            speaker.speak(id: entry.id, text: entry.text, settings: voiceSettings)
        }
    }

    private func playHermesSpeech(_ entry: ChatEntry, seq: Int) {
        loadingSpeech = entry.id
        let profileId = gateway.activeProfileId
        Task {
            defer { loadingSpeech = nil }
            do {
                let urls = try await gateway.hermesSpeech(for: seq, in: profileId)
                guard profileId == gateway.activeProfileId else { return }
                player.expectsMore = false
                player.play(id: "speech-" + entry.id, urls: urls, from: 0)
            } catch {
                // Hermes' voice failed: say it with the iPhone's instead.
                speaker.speak(id: entry.id, text: entry.text, settings: voiceSettings)
            }
        }
    }

    /// Voice mode: a reply's spoken parts (saved, or still arriving).
    private func spokenParts(_ entry: ChatEntry) -> [ChatFile]? {
        if let saved = entry.spoken, !saved.isEmpty { return saved }
        if let live = gateway.liveSpeech[entry.id], !live.isEmpty { return live }
        return nil
    }

    private func isLiveSpoken(_ entry: ChatEntry) -> Bool {
        entry.spoken == nil && gateway.liveSpeech[entry.id] != nil
    }

    /// Voice mode is on for this agent (its replies come as voice notes).
    private var voiceMode: Bool { voiceSettings.speak != "off" }

    private func toggleVoiceMode() {
        let profileId = gateway.activeProfileId
        let mode = voiceMode ? "off" : "always"
        if mode == "off" { speaker.stop(); player.stop() }
        Task { try? await gateway.setVoiceReplies(mode, for: profileId) }
    }

    /// The newest reply's live spoken parts, to play each as it arrives.
    private var newestLiveParts: LiveParts? {
        guard let entry = messages.last(where: { $0.role == .agent }),
              let parts = gateway.liveSpeech[entry.id] else { return nil }
        return LiveParts(id: entry.id, count: parts.count, done: entry.spoken != nil)
    }

    private func playLiveParts(_ live: LiveParts) {
        guard scenePhase == .active, !recorder.isRecording, recorder.draft == nil,
              let parts = gateway.liveSpeech[live.id], let part = parts.last else { return }
        player.expectsMore = !live.done
        let id = live.id
        Task {
            guard let url = try? await gateway.fileURL(for: part) else { return }
            player.append(id: id, url: url)
        }
    }

    /// The newest reply (and whether it's still being written), to speak it as it comes.
    private var newestReply: SpeakableReply? {
        guard let entry = messages.last(where: { $0.role == .agent }) else { return nil }
        return SpeakableReply(id: entry.id, text: entry.text, final: entry.status != .streaming)
    }

    private func autoSpeak(_ reply: SpeakableReply) {
        guard voiceSettings.speak != "off", scenePhase == .active, !recorder.isRecording, recorder.draft == nil,
              let entry = messages.last(where: { $0.id == reply.id }),
              entry.status == .streaming || (entry.date ?? .distantPast) > openedAt else { return }
        if voiceSettings.speak == "voice_notes" {
            // Only replies to a voice note.
            guard let index = messages.firstIndex(where: { $0.id == reply.id }),
                  messages[..<index].last(where: { $0.role == .user })?.voice != nil else { return }
        }
        // With a Hermes voice the instance sends the reply as a voice note (streamed parts,
        // played as they come); without one the iPhone voice reads it as it's written.
        guard gateway.hermesVoice[gateway.activeProfileId]?.available != true else { return }
        speaker.follow(id: reply.id, text: reply.text, final: reply.final, settings: voiceSettings)
    }

    // MARK: - Voice notes (docs/voice.md)

    /// The mic sits in the message bar while there's nothing typed or attached.
    private var showsMic: Bool {
        isConnected && !uploading && attachments.isEmpty
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// While recording, and while a recorded note waits to be sent, the whole bar is the
    /// voice note (as in Messages).
    private var voiceBar: AnyView? {
        if recorder.isRecording {
            return AnyView(LKRecordingBar(elapsed: recorder.elapsed, levels: recorder.levels) {
                Task { await recorder.stop() }
            })
        }
        if let note = recorder.draft {
            return AnyView(LKVoiceDraftBar(
                duration: note.duration, waveform: note.waveform,
                isPlaying: player.currentId == Self.draftId && player.isPlaying,
                progress: player.currentId == Self.draftId ? player.progress : 0,
                busy: recorder.isFinishing,
                onDiscard: { player.stop(); recorder.discard() },
                onToggle: { player.toggle(id: Self.draftId, url: note.url) },
                onSeek: { player.seek(id: Self.draftId, url: note.url, to: $0) },
                onRecordMore: startRecording,
                onSend: sendRecording))
        }
        if recorder.isFinishing {
            return AnyView(ProgressView().frame(maxWidth: .infinity, minHeight: 44))
        }
        return nil
    }

    private static let draftId = "voice-draft"

    /// idle / recording / review, for the bar's animation.
    private var voiceStage: String {
        if recorder.isRecording { return "recording" }
        if recorder.draft != nil || recorder.isFinishing { return "review" }
        return "idle"
    }

    /// Tap the mic (or "+" on a recorded note): recording starts, no need to hold.
    private func startRecording() {
        player.stop()
        speaker.stop()
        Task {
            guard await recorder.requestPermission() else {
                attachmentProblem = "Lekora needs the microphone for voice notes. You can allow it in Settings › Lekora."
                return
            }
            do {
                try recorder.start()
            } catch {
                attachmentProblem = "Couldn't start recording: \(error.localizedDescription)"
            }
        }
    }

    private func sendRecording() {
        player.stop()
        guard let note = recorder.takeDraft() else { return }
        isAtBottom = true
        scrollToBottom(animated: true)
        Task {
            do {
                try await gateway.sendVoiceNote(at: note.url, duration: note.duration, waveform: note.waveform)
            } catch {
                attachmentProblem = "The voice note didn't send: \(error.localizedDescription)"
            }
            try? FileManager.default.removeItem(at: note.url)
        }
    }

    /// Plays a voice note (fetching it from the instance first if needed), or pauses it.
    private func toggleVoice(_ entry: ChatEntry, file: ChatFile) {
        if let url = gateway.cachedFileURL(file) {
            player.toggle(id: entry.id, url: url)
            return
        }
        loadingVoice = entry.id
        Task {
            defer { loadingVoice = nil }
            if let url = try? await gateway.fileURL(for: file) { player.toggle(id: entry.id, url: url) }
        }
    }

    private func seekVoice(_ entry: ChatEntry, file: ChatFile, to fraction: Double) {
        guard let url = gateway.cachedFileURL(file) else { return }
        player.seek(id: entry.id, url: url, to: fraction)
    }

    // MARK: - Photos and files (docs/files.md)

    private var attachMenu: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhotos = true }
            #if os(iOS)
            if CameraPicker.isAvailable {
                Button("Take Photo", systemImage: "camera") { takingPhoto = true }
            }
            #endif
            Button("Choose Files", systemImage: "folder") { choosingFiles = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .menuOrder(.fixed)  // same order every time: Photo Library at the top
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(!isConnected || uploading || attachments.count >= GatewayClient.maxFilesPerMessage)
        .accessibilityLabel("Add photos or files")
    }

    private func addAttachment(_ item: LKPendingAttachment) {
        guard attachments.count < GatewayClient.maxFilesPerMessage else {
            attachmentProblem = "Up to \(GatewayClient.maxFilesPerMessage) photos or files per message."
            return
        }
        attachments.append(item)
    }

    /// "Sending…" / "Not delivered" under a message that is only photos or files.
    @ViewBuilder
    private func fileOnlyStatus(for entry: ChatEntry) -> some View {
        switch delivery(for: entry) {
        case .sending:
            Text("Sending…").font(LK.Typography.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .failed(let reason):
            Label("Not delivered: \(reason)", systemImage: "exclamationmark.circle")
                .font(LK.Typography.caption).foregroundStyle(LK.Palette.danger)
                .frame(maxWidth: .infinity, alignment: .trailing)
        default:
            EmptyView()
        }
    }

    /// Opens a photo or file in Quick Look (fetching it from the instance first if needed).
    private func openFile(_ file: ChatFile) {
        if let cached = gateway.cachedFileURL(file) {
            previewURL = cached
            return
        }
        openingFile = file.file_id
        Task {
            defer { openingFile = nil }
            do {
                previewURL = try await gateway.fileURL(for: file)
            } catch {
                attachmentProblem = "Couldn't open \(file.name): \(error.localizedDescription)"
            }
        }
    }

    /// Uploads every attachment (keeping the text until they're all there), then sends.
    private func sendWithAttachments(_ text: String) {
        uploading = true
        let profileId = gateway.activeProfileId
        Task {
            defer { uploading = false }
            var sent: [ChatFile] = []
            for index in attachments.indices {
                if let done = attachments[index].uploaded {
                    sent.append(done)
                    continue
                }
                attachments[index].failure = nil
                attachments[index].progress = 0
                let item = attachments[index]
                do {
                    let file = try await gateway.uploadFile(at: item.url, name: item.name, mime: item.mime, to: profileId) { value in
                        Task { @MainActor in
                            if let i = attachments.firstIndex(where: { $0.id == item.id }) { attachments[i].progress = value }
                        }
                    }
                    if let i = attachments.firstIndex(where: { $0.id == item.id }) { attachments[i].uploaded = file }
                    sent.append(file)
                } catch {
                    if let i = attachments.firstIndex(where: { $0.id == item.id }) {
                        attachments[i].failure = error.localizedDescription
                        attachments[i].progress = nil
                    }
                    attachmentProblem = "\(item.name) didn't upload: \(error.localizedDescription). Tap send to try again."
                    return
                }
            }
            for item in attachments { try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent()) }
            attachments = []
            if draft == text {
                draft = ""
                gateway.drafts[profileId] = nil
                composerID += 1
            }
            isAtBottom = true
            scrollToBottom(animated: true)
            await gateway.sendMessage(text, files: sent)
        }
    }

    private func updateVisibility() {
        gateway.setChatVisible(isOnScreen && scenePhase == .active)
    }

    private var unreadBadge: some View {
        Text("\(unreadOthers)")
            .font(LK.Typography.captionStrong)
            .foregroundStyle(LK.Palette.onAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(LK.Palette.accent, in: Capsule())
            .accessibilityLabel(gateway.otherAgentsWithUnread == 1
                                ? "1 other agent with new messages"
                                : "\(gateway.otherAgentsWithUnread) other agents with new messages")
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: LK.Spacing.sm) {
                if gateway.canLoadOlder(gateway.activeProfileId) {
                    // Older messages are on the host; they load when scrolling up near here.
                    ProgressView()
                        .opacity(gateway.loadingOlder.contains(gateway.activeProfileId) ? 1 : 0)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LK.Spacing.sm)
                } else if messages.isEmpty {
                    emptyState
                }
                let timeLines = LKTime.separatorIds(for: messages)
                ForEach(messages) { entry in
                    Group {
                        if timeLines.contains(entry.id), let date = entry.date {
                            LKTimeSeparator(date)
                        }
                        if entry.role == .system {
                            LKSystemNotice(entry.text)
                        } else if let card = entry.card {
                            LKPromptCard(card, agentName: profileName, actions: promptActions(for: card))
                        } else {
                            if entry.role == .agent, let parts = spokenParts(entry) {
                                SpokenReplyBubble(entry: entry, parts: parts, live: isLiveSpoken(entry),
                                                  gateway: gateway, player: player)
                                    .offset(x: -timeReveal)
                            } else if let voice = entry.voice, let file = entry.files?.first {
                                LKVoiceBubble(voice, fromUser: entry.role == .user, transcript: entry.transcript,
                                              isPlaying: player.currentId == entry.id && player.isPlaying,
                                              progress: player.currentId == entry.id ? player.progress : 0,
                                              loading: loadingVoice == entry.id,
                                              onToggle: { toggleVoice(entry, file: file) },
                                              onSeek: { seekVoice(entry, file: file, to: $0) })
                                    .offset(x: -timeReveal)
                                fileOnlyStatus(for: entry)
                            } else if let files = entry.files, !files.isEmpty {
                                LKMessageFiles(files, fromUser: entry.role == .user, opening: openingFile,
                                               load: { file in try? await gateway.fileURL(for: file) },
                                               open: openFile)
                                    .offset(x: -timeReveal)
                            }
                            if entry.voice != nil || (entry.role == .agent && spokenParts(entry) != nil) {
                                EmptyView()
                            } else if entry.files?.isEmpty == false && entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                fileOnlyStatus(for: entry)  // just photos or files: no empty text bubble
                            } else {
                                LKMessageBubble(entry.text, from: entry.role == .user ? .user : .agent,
                                                delivery: delivery(for: entry))
                                    .offset(x: -timeReveal)
                                    .overlay(alignment: .bottomLeading) {
                                        if entry.role == .agent, entry.status != .streaming,
                                           !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            LKListenButton(speaking: isSpeaking(entry), loading: loadingSpeech == entry.id) {
                                                listen(to: entry)
                                            }
                                            .padding(.leading, LK.Spacing.xs)
                                            .offset(x: -timeReveal, y: 26)
                                        }
                                    }
                                    .padding(.bottom, entry.role == .agent && entry.status != .streaming ? 22 : 0)
                                    .overlay(alignment: .trailing) {
                                        if let date = entry.date {
                                            Text(date.formatted(date: .omitted, time: .shortened))
                                                .font(LK.Typography.caption)
                                                .foregroundStyle(.secondary)
                                                .fixedSize()
                                                .offset(x: Self.timeRevealWidth - timeReveal)
                                                .opacity(timeReveal / Self.timeRevealWidth)
                                                .accessibilityHidden(true)
                                        }
                                    }
                            }
                        }
                    }
                    .id(entry.id)
                }
                if showsTypingIndicator {
                    LKTypingIndicator(status: statusText, since: activity?.since)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, LK.Spacing.lg)
            .padding(.vertical, LK.Spacing.md)
        }
        #if os(iOS)
        // Drag left to see every message's time; let go and they slide back (as in Messages).
        // Only leftward drags: swiping right still goes back to the agents list.
        .gesture(LKLeftwardPan(
            onChange: { distance in timeReveal = min(distance, Self.timeRevealWidth) },
            onEnd: { withAnimation(.spring(duration: 0.3)) { timeReveal = 0 } }))
        #endif
        .onScrollPhaseChange { _, phase in
            userIsScrolling = phase == .interacting || phase == .decelerating
        }
        // Follow the bottom EDGE, not a message id: the list measures bubbles lazily and
        // they change height while streaming, so scrolling to an id could stop short
        // (new reply out of view) or leave a gap above the message bar.
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            // "At the bottom" = the visible area reaches the end of the content
            // (visibleRect already excludes the keyboard and message bar).
            geometry.visibleRect.maxY >= geometry.contentSize.height - Self.bottomSlack
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        .onScrollGeometryChange(for: TopEdge.self) { geometry in
            TopEdge(distance: geometry.visibleRect.minY,
                    fits: geometry.contentSize.height <= geometry.containerSize.height)
        } action: { old, new in
            // Scrolling up to the top, or a chat too short to scroll: fetch the page before.
            let reachedTop = userIsScrolling && new.distance < Self.loadOlderZone && new.distance < old.distance
            if reachedTop || new.fits {
                loadOlder()
            }
        }
        // A fresh list per agent, so switching opens that agent's chat at its newest message.
        .id(gateway.activeProfileId)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onChange(of: contentSignature) { _, _ in
            // New message, growing live reply, thinking bubble on/off: follow along, but
            // only if the reader is already at the bottom (never yank them out of history).
            if isAtBottom { scrollToBottom(animated: true) }
        }
        .animation(.easeOut(duration: 0.2), value: showsTypingIndicator)
        .onChange(of: inputFocused) { _, focused in
            // The keyboard shrinks the visible area: keep the newest message in view.
            if focused && isAtBottom { scrollToBottom(animated: true) }
        }
        .onChange(of: gateway.activeProfileId) { _, _ in
            isAtBottom = true
            scrollPosition = ScrollPosition(edge: .bottom)
        }
    }

    /// How far from the end still counts as "at the bottom".
    private static let bottomSlack: CGFloat = 80

    /// Changes whenever the bottom of the chat changes (not when older messages load above).
    private var contentSignature: String {
        "\(messages.last?.id ?? "")|\(messages.last?.text.count ?? 0)|\(showsTypingIndicator)|\((statusText ?? "").count)"
    }

    /// Where the top of the visible area is, and whether the whole chat fits on screen.
    private struct TopEdge: Equatable {
        var distance: CGFloat
        var fits: Bool
    }

    /// How close to the top scrolling up starts loading older messages.
    private static let loadOlderZone: CGFloat = 60

    /// Loads the page before the oldest message shown. The reader is at the top, so that
    /// message is put back at the top afterwards (the list would otherwise keep its distance
    /// from the top and jump to the new, older messages).
    private func loadOlder() {
        let profileId = gateway.activeProfileId
        guard !pageInFlight, gateway.canLoadOlder(profileId),
              !gateway.loadingOlder.contains(profileId) else { return }
        pageInFlight = true
        Task {
            guard let page = await gateway.fetchOlderPage(profileId) else {
                pageInFlight = false
                return
            }
            // iOS ignores moving the list while a finger is on it: add the page once the
            // drag (and any coasting) has ended.
            while userIsScrolling {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard profileId == gateway.activeProfileId else {
                pageInFlight = false
                return
            }
            let anchor = messages.first?.id
            let keepPlace = !isAtBottom
            gateway.applyOlderPage(page, for: profileId)
            DispatchQueue.main.async {
                if keepPlace, let anchor {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    // Through the list's own position, so it isn't later reset to the
                    // "at the top" it held while the reader was scrolling.
                    withTransaction(transaction) {
                        scrollPosition.scrollTo(id: anchor, anchor: .top)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pageInFlight = false }
            }
        }
    }

    private func scrollToBottom(animated: Bool) {
        // Wait one layout pass so the new content is measured before scrolling to the edge.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) }
            } else {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: LK.Spacing.md) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: LK.Size.heroIcon))
                .foregroundStyle(LK.Palette.accent.gradient)
            Text("Say hello to \(profileName)")
                .font(LK.Typography.headline)
            Text("Messages you send here go to your agent on \(instanceName).")
                .font(LK.Typography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
        .padding(.horizontal, LK.Spacing.xxl)
    }

    /// Answers from a card go to the host, for this chat's agent (docs/prompts.md).
    private func promptActions(for card: PromptCard) -> LKPromptActions {
        let profileId = gateway.activeProfileId
        return LKPromptActions(
            approve: { choice, reason in
                try await gateway.answerApproval(card, in: profileId, choice: choice, reason: reason)
            },
            answer: { answers, text in
                try await gateway.answerQuestion(card, in: profileId, answers: answers, text: text)
            },
            pickModel: { model, provider, confirmed, scope in
                try await gateway.pickModel(card, in: profileId, model: model, provider: provider,
                                            confirmed: confirmed, scope: scope)
            },
            models: LKModelSource(
                catalog: { provider, models in
                    try await gateway.modelCatalog(provider: provider, models: models, in: profileId).models
                },
                hosts: { model in try await gateway.modelHosts(model, in: profileId) },
                setRouting: { model, mode, hosts, noTraining in
                    try await gateway.setRouting(model, mode: mode, hosts: hosts, noTraining: noTraining, in: profileId)
                }))
    }

    private func delivery(for entry: ChatEntry) -> LKMessageBubble.Delivery {
        switch entry.status {
        case .sending: return .sending
        case .sent: return .delivered
        case .failed(let reason): return .failed(reason)
        case .streaming: return .streaming
        }
    }


    private func send() {
        guard canSend else { return }
        if !attachments.isEmpty {
            sendWithAttachments(draft)
            return
        }
        let text = draft
        draft = ""
        gateway.drafts[gateway.activeProfileId] = nil
        // A fresh text box (see composerID), keeping the keyboard up.
        composerID += 1
        DispatchQueue.main.async { inputFocused = true }
        isAtBottom = true          // you just sent something: show it, and the reply
        scrollToBottom(animated: true)
        Task {
            await gateway.sendMessage(text)
        }
    }
}

/// The newest reply as the chat screen sees it, for speaking it as it arrives.
struct SpeakableReply: Equatable {
    let id: String
    let text: String
    let final: Bool
}

/// The newest reply's spoken parts so far.
struct LiveParts: Equatable {
    let id: String
    let count: Int
    let done: Bool
}

/// A reply in voice mode: a voice note in the agent's Hermes voice (parts played one after the
/// other), its text as the transcript. While it's still arriving, it fills in as parts come.
struct SpokenReplyBubble: View {
    let entry: ChatEntry
    let parts: [ChatFile]
    let live: Bool
    @ObservedObject var gateway: GatewayClient
    @ObservedObject var player: VoicePlayer
    @State private var details: VoiceDetails?
    @State private var loading = false

    private var shown: VoiceDetails {
        details ?? VoiceDetails(duration: max(Double(entry.text.split(separator: " ").count) / 2.6, 1),
                                waveform: Array(repeating: 0.25, count: 32))
    }

    var body: some View {
        LKVoiceBubble(shown, fromUser: false, transcript: entry.text,
                      isPlaying: player.currentId == entry.id && player.isPlaying,
                      progress: player.currentId == entry.id ? player.progress : 0,
                      loading: loading,
                      onToggle: toggle, onSeek: seek)
            .task(id: parts.count) { await measure() }
    }

    private func localParts() async -> [URL]? {
        var urls: [URL] = []
        for part in parts {
            guard let url = try? await gateway.fileURL(for: part) else { return nil }
            urls.append(url)
        }
        return urls
    }

    /// Length and waveform from the audio itself, once it's here.
    private func measure() async {
        guard let urls = await localParts() else { return }
        let measured = await Task.detached(priority: .utility) { () -> VoiceDetails in
            VoiceDetails(duration: urls.reduce(0) { $0 + VoicePlayer.lengthNonisolated(of: $1) },
                         waveform: VoiceWaveform.bars(of: urls))
        }.value
        details = measured
    }

    private func toggle() {
        if player.currentId == entry.id {
            player.toggle(id: entry.id, urls: [])
            return
        }
        loading = true
        Task {
            defer { loading = false }
            guard let urls = await localParts() else { return }
            player.expectsMore = live
            player.play(id: entry.id, urls: urls, from: 0)
        }
    }

    private func seek(_ fraction: Double) {
        Task {
            guard let urls = await localParts() else { return }
            player.seek(id: entry.id, urls: urls, to: fraction)
        }
    }
}
