import SwiftUI

/// Past chats (docs/chats.md): an agent's conversations as Hermes keeps them, newest first.
/// The current one is marked; an earlier one can be read here, or continued (Hermes' own
/// /resume), which makes it the chat again.
struct PastChatsView: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String
    /// Opened on its own (the chat's "Earlier chats"), not pushed from Chat Settings.
    var standalone = false
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var query = ""
    @State private var results: [ChatSessionInfo]?
    @State private var searching = false

    private var chats: [ChatSessionInfo] { results ?? gateway.pastChats[profileId] ?? [] }

    var body: some View {
        List {
            if chats.isEmpty, results != nil {
                Text(searching ? "Searching…" : "No chats with “\(query)”.")
                    .font(LK.Typography.callout)
                    .foregroundStyle(.secondary)
            } else if chats.isEmpty {
                if loaded {
                    Text("No earlier chats with \(agentName) yet. When you start a New Chat, the one before is kept here.")
                        .font(LK.Typography.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            ForEach(chats) { chat in
                NavigationLink {
                    PastChatView(gateway: gateway, profileId: profileId, agentName: agentName, chat: chat) {
                        dismiss()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(chat.name).lineLimit(1)
                            if chat.current {
                                Text("Current")
                                    .font(LK.Typography.caption.weight(.semibold))
                                    .foregroundStyle(LK.Palette.accent)
                            }
                        }
                        Text(detail(chat))
                            .font(LK.Typography.caption)
                            .foregroundStyle(.secondary)
                        if let match = chat.match {
                            Text(match)
                                .font(LK.Typography.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search chats")
        .task(id: query) {
            // Titles and every message, on the instance; a moment after typing stops.
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { results = nil; return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            searching = true
            results = (try? await gateway.searchChats(text, in: profileId)) ?? []
            searching = false
        }
        .navigationTitle("Past Chats")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if standalone {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            await gateway.loadChats(for: profileId)
            loaded = true
        }
        .refreshable { await gateway.loadChats(for: profileId) }
    }

    private func detail(_ chat: ChatSessionInfo) -> String {
        var parts: [String] = []
        if let date = chat.lastDate { parts.append(date.formatted(.relative(presentation: .named))) }
        if chat.messages > 0 { parts.append("\(chat.messages) message\(chat.messages == 1 ? "" : "s")") }
        if chat.title != nil, let preview = chat.preview { parts.append(preview) }
        return parts.joined(separator: " · ")
    }
}

/// One past chat, to read; "Continue This Chat" makes it the chat again.
struct PastChatView: View {
    @ObservedObject var gateway: GatewayClient
    let profileId: String
    let agentName: String
    let chat: ChatSessionInfo
    let continued: () -> Void
    @State private var messages: [ChatMessageData]?
    @State private var failure: String?
    @State private var resuming = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: LK.Spacing.sm) {
                if let messages {
                    if messages.isEmpty {
                        Text("Nothing from this chat is kept in Lekora (it may have happened elsewhere, or before Lekora).")
                            .font(LK.Typography.callout)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(messages, id: \.seq) { message in
                        row(message)
                    }
                } else if let failure {
                    LKNotice(.warning, failure).padding()
                } else {
                    ProgressView().padding()
                }
            }
            .padding(.horizontal, LK.Spacing.lg)
            .padding(.vertical, LK.Spacing.md)
        }
        .defaultScrollAnchor(.bottom)
        .lkScreenBackground()
        .navigationTitle(chat.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom) {
            if !chat.current {
                LKPrimaryButton(resuming ? "Continuing…" : "Continue This Chat", systemImage: "arrow.uturn.forward") {
                    resume()
                }
                .disabled(resuming)
                .padding(.horizontal, LK.Spacing.lg)
                .padding(.vertical, LK.Spacing.sm)
                .background(.bar)
            }
        }
        .task {
            do {
                messages = try await gateway.chatHistory(chat.session_id, in: profileId)
            } catch {
                failure = "Couldn't load it: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func row(_ message: ChatMessageData) -> some View {
        let fromUser = message.role == "user"
        if message.role == "system" {
            LKSystemNotice(message.text)
        } else if let artifact = message.artifact {
            LKArtifactCard(artifact: artifact, fromUser: fromUser) {}
        } else if let review = message.review, !review.isEmpty {
            LKReviewCard(artifact: message.about, comments: review) {}
        } else {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = !text.isEmpty ? message.text
                : message.voice != nil ? "🎤 Voice note" + (message.transcript.map { ": \($0)" } ?? "")
                : (message.files?.isEmpty == false ? "📎 " + (message.files ?? []).map(\.name).joined(separator: ", ") : "")
            if !shown.isEmpty {
                LKMessageBubble(shown, from: fromUser ? .user : .agent)
            }
        }
    }

    private func resume() {
        resuming = true
        Task {
            defer { resuming = false }
            do {
                try await gateway.resumeChat(chat.session_id, in: profileId)
                continued()
            } catch {
                failure = "Couldn't continue it: \(error.localizedDescription)"
            }
        }
    }
}
