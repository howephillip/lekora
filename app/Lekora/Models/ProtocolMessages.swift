import Foundation

// MARK: - Generic Protocol Envelope
public struct Envelope<T: Codable>: Codable {
    public let v: Int
    public let id: String
    public let type: String
    public let instance_id: String
    public let profile_id: String?
    public let ts: String
    public let data: T

    public init(
        v: Int = 1,
        id: String = UUID().uuidString,
        type: String,
        instance_id: String,
        profile_id: String? = nil,
        ts: String = ISO8601DateFormatter().string(from: Date()),
        data: T
    ) {
        self.v = v
        self.id = id
        self.type = type
        self.instance_id = instance_id
        self.profile_id = profile_id
        self.ts = ts
        self.data = data
    }
}

/// Just enough of an envelope to decide how to decode the rest.
public struct EnvelopeHeader: Codable {
    public let type: String
    public let id: String
    public let profile_id: String?
    /// The computer it came from; a message for another computer is ignored.
    public let instance_id: String?
}

// MARK: - Pairing Payloads
public struct PairRequestData: Codable, Equatable {
    public let pairing_token: String
    public let device_name: String
    public let client_version: String
    public let supported_proto_versions: [Int]

    public init(
        pairing_token: String,
        device_name: String,
        client_version: String = "1.0.0",
        supported_proto_versions: [Int] = [1]
    ) {
        self.pairing_token = pairing_token
        self.device_name = device_name
        self.client_version = client_version
        self.supported_proto_versions = supported_proto_versions
    }
}

public struct PairResponseData: Codable, Equatable {
    public let status: String
    public let proto_version: Int
    public let device_id: String
    public let device_token: String
    public let instance_name: String
    public let endpoints: [String]

    public init(
        status: String = "ok",
        proto_version: Int = 1,
        device_id: String,
        device_token: String,
        instance_name: String,
        endpoints: [String]
    ) {
        self.status = status
        self.proto_version = proto_version
        self.device_id = device_id
        self.device_token = device_token
        self.instance_name = instance_name
        self.endpoints = endpoints
    }
}

// MARK: - Session Handshake Payloads
public struct HelloData: Codable, Equatable {
    public let device_id: String
    public let device_token: String
    public let last_seq: Int
    /// Highest change number this phone has (0 = no cache); the host replays changes since
    /// it (docs/chat-history.md). Absent from apps before chat history.
    public let since_rev: Int?
    public let client_version: String
    public let proto_version: Int

    public init(
        device_id: String,
        device_token: String,
        last_seq: Int = 0,
        since_rev: Int? = nil,
        client_version: String = "1.0.0",
        proto_version: Int = 1
    ) {
        self.device_id = device_id
        self.device_token = device_token
        self.last_seq = last_seq
        self.since_rev = since_rev
        self.client_version = client_version
        self.proto_version = proto_version
    }
}

public struct ProfileData: Codable, Identifiable, Equatable {
    public var id: String { profile_id }
    public let profile_id: String
    public let name: String
    public let avatar: String
    /// What this agent is for, from the Hermes profile's `profile.yaml` (optional).
    public let description: String?

    public init(profile_id: String, name: String, avatar: String, description: String? = nil) {
        self.profile_id = profile_id
        self.name = name
        self.avatar = avatar
        self.description = description
    }
}

public struct HelloAckData: Codable, Equatable {
    public let status: String
    public let current_seq: Int
    public let instance_name: String
    public let profiles: [ProfileData]
    /// The host's current change number (hosts with chat history).
    public let rev: Int?
    /// "changes" (only what changed since `since_rev` follows) or "recent" (each agent's
    /// newest messages follow; drop cached ones). Absent from older hosts.
    public let replay: String?
    /// Each agent's read marker: highest seq read on any of the user's phones.
    public let read: [String: Int]?
    /// True when messages carry the time they were saved (`at`).
    public let message_times: Bool?
    /// What this instance's agents call you ("" not chosen yet; absent from older plugins).
    public let user_name: String?

    public init(
        status: String = "ok",
        current_seq: Int,
        instance_name: String,
        profiles: [ProfileData],
        rev: Int? = nil,
        replay: String? = nil,
        read: [String: Int]? = nil,
        message_times: Bool? = nil,
        user_name: String? = nil
    ) {
        self.status = status
        self.current_seq = current_seq
        self.instance_name = instance_name
        self.profiles = profiles
        self.rev = rev
        self.replay = replay
        self.read = read
        self.message_times = message_times
        self.user_name = user_name
    }
}

// MARK: - Walking Skeleton Chat Payloads
public struct ChatSendData: Codable, Equatable {
    public let text: String
    /// Uploaded files sent with the message (docs/files.md).
    public let files: [String]?
    /// Set for a voice note (its one file is the recording; docs/voice.md).
    public let voice: VoiceDetails?
    /// Sent from a hands-free conversation: the reply is spoken (docs/voice.md §3).
    public let hands_free: Bool?
    /// "Ask to change" an artifact: which one (docs/artifacts.md).
    public let about: ArtifactRef?
    /// With `about`: comments on its lines, sent together.
    public let review: [ReviewComment]?

    public init(text: String, files: [String]? = nil, voice: VoiceDetails? = nil, hands_free: Bool? = nil,
                about: ArtifactRef? = nil, review: [ReviewComment]? = nil) {
        self.about = about
        self.review = review
        self.text = text
        self.files = files
        self.voice = voice
        self.hands_free = hands_free
    }
}

/// A voice note's length (seconds) and waveform (levels 0…1), for its bubble.
public struct VoiceDetails: Codable, Equatable, Hashable, Sendable {
    public let duration: Double
    public let waveform: [Double]

    public init(duration: Double, waveform: [Double]) {
        self.duration = duration
        self.waveform = waveform
    }
}

// MARK: - Files (docs/files.md)

/// A photo or file in a message, kept on the Hermes instance.
public struct ChatFile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let file_id: String
    public let name: String
    public let mime: String
    public let size: Int
    /// image | video | audio | document
    public let kind: String

    public var id: String { file_id }
    public var isImage: Bool { kind == "image" }

    public init(file_id: String, name: String, mime: String, size: Int, kind: String) {
        self.file_id = file_id
        self.name = name
        self.mime = mime
        self.size = size
        self.kind = kind
    }
}

struct FileUploadBeginData: Codable { let name: String; let mime: String; let size: Int }
struct FileUploadBeginResult: Codable { let file_id: String; let chunk_size: Int }
struct FileUploadChunkData: Codable { let file_id: String; let offset: Int; let data: String }
struct FileUploadChunkResult: Codable { let file_id: String; let received: Int }
struct FileIdData: Codable { let file_id: String }
struct FileUploadEndResult: Codable { let file: ChatFile }
struct FileReadData: Codable { let file_id: String; let offset: Int }
struct FileReadResult: Codable { let file_id: String; let offset: Int; let data: String; let size: Int; let done: Bool }

// MARK: - Hearing replies (docs/voice.md §2)

/// An agent's voice settings, kept on the Hermes instance.
public struct AgentVoiceSettings: Codable, Equatable, Sendable {
    /// Voice replies: off | voice_notes | always
    public var speak: String
    /// Listen button: iphone | hermes
    public var engine: String
    /// An iPhone voice identifier; nil = the iPhone's default for its language.
    public var voice: String?
    /// 0…1 (0.5 = normal speed).
    public var rate: Double
    /// Voice replies: tts (the reply as written) | personality (rewritten as a voice script).
    public var style: String
    /// Personality voice: hermes (the agent's own Hermes persona) | preset (one of Hermes'
    /// personalities, `style_preset`) | custom (the user's words).
    public var style_source: String
    public var style_preset: String?
    /// Personality voice: the user's own personality, when `style_source` is custom.
    public var style_instructions: String?
    /// Personality voice cadence, each 0…2: filler words, pauses, pace.
    public var fillers: Int
    public var pauses: Int
    public var pace: Int

    public init(speak: String = "off", engine: String = "iphone", voice: String? = nil, rate: Double = 0.5,
                style: String = "tts", style_source: String = "hermes", style_preset: String? = nil,
                style_instructions: String? = nil, fillers: Int = 1, pauses: Int = 1, pace: Int = 1) {
        self.style_source = style_source
        self.style_preset = style_preset
        self.fillers = fillers
        self.pauses = pauses
        self.pace = pace
        self.speak = speak
        self.engine = engine
        self.voice = voice
        self.rate = rate
        self.style = style
        self.style_instructions = style_instructions
    }

    /// Hosts from before voice styles don't send them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speak = try c.decodeIfPresent(String.self, forKey: .speak) ?? "off"
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "iphone"
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 0.5
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? "tts"
        style_instructions = try c.decodeIfPresent(String.self, forKey: .style_instructions)
        style_source = try c.decodeIfPresent(String.self, forKey: .style_source) ?? "hermes"
        style_preset = try c.decodeIfPresent(String.self, forKey: .style_preset)
        fillers = try c.decodeIfPresent(Int.self, forKey: .fillers) ?? 1
        pauses = try c.decodeIfPresent(Int.self, forKey: .pauses) ?? 1
        pace = try c.decodeIfPresent(Int.self, forKey: .pace) ?? 1
    }

    public static let standard = AgentVoiceSettings()
}

/// Whether the agent has a cloud voice set up in Hermes (and which).
public struct HermesVoiceInfo: Codable, Equatable, Sendable {
    public let available: Bool
    public let provider: String?
}

struct VoiceSettingsGetResult: Codable {
    let settings: AgentVoiceSettings
    let hermes_voice: HermesVoiceInfo
    let default_style_instructions: String?
}
/// Voice mode: this reply is a voice note (tts | personality), from its first word; or why its
/// audio can't be played.
struct VoiceReplyData: Codable {
    let message_id: String; let style: String; let problem: String?
    /// Its sound also comes as `voice.stream` while it's made (direct voice, docs/voice.md §4).
    let streaming: Bool?
}

/// Direct voice: sound for one part of a reply as it's made (16-bit mono PCM, base64).
public struct VoiceStreamData: Codable, Sendable {
    public let message_id: String
    public let index: Int
    public let chunk: Int
    public let rate: Int
    public let data: String
    public let last: Bool?
}

// MARK: - Direct voice (docs/voice.md §4)

public struct DirectVoiceSettings: Codable, Equatable, Sendable {
    public struct Fish: Codable, Equatable, Sendable { public var voice_id: String; public var model: String; public var speed: Double }
    public struct ElevenLabs: Codable, Equatable, Sendable { public var voice_id: String; public var model_id: String }
    public struct OpenAI: Codable, Equatable, Sendable { public var base_url: String; public var model: String; public var voice: String }
    /// auto | fish | elevenlabs | openai | off
    public var source: String
    public var fish: Fish
    public var elevenlabs: ElevenLabs
    public var openai: OpenAI
}

public struct DirectVoiceInfo: Codable, Equatable, Sendable {
    public let settings: DirectVoiceSettings
    /// Where each service's key comes from: "app", a Hermes .env name (e.g. "FISH_API_KEY"), or "".
    public let keys: [String: String]
    /// Hermes' own streaming voice for this agent ("Hermes (elevenlabs)"), or nil when it can't stream it.
    public let hermes_streaming: String?
}

struct DirectVoiceKey: Codable { let provider: String; let value: String }
struct DirectVoiceSetData: Codable { let settings: DirectVoiceSettings; let key: DirectVoiceKey? }
struct DirectVoiceTestResult: Codable { let file: ChatFile }

// MARK: - An agent's tools in Lekora chats (docs/agent-tools.md)

public struct AgentToolset: Codable, Equatable, Identifiable, Sendable {
    public let key: String
    public let label: String
    public let description: String?
    public var enabled: Bool
    public var id: String { key }
}

public struct AgentToolsData: Codable, Equatable, Sendable {
    public var toolsets: [AgentToolset]
    /// The lists saved for the agent's other chat platforms (e.g. telegram), to copy from.
    public let elsewhere: [String: [String]]?
    public let problem: String?
}

struct AgentToolsChange: Codable { let changes: [String: Bool] }
struct VoiceSettingsData: Codable { let settings: AgentVoiceSettings }
struct VoiceSpeakData: Codable { let seq: Int }
struct VoiceSpeakResult: Codable { let seq: Int; let file: ChatFile; let files: [ChatFile]? }
/// A spoken part of a reply in voice mode, to play at once.
struct VoiceSegmentData: Codable {
    let message_id: String; let index: Int; let file: ChatFile; let script: String?
    /// A small part's audio itself (base64), so it plays without fetching.
    let data: String?
}

struct VoiceLogData: Codable { let line: String }

/// How long a hands-free turn took on the phone, for the instance's log (docs/voice.md §3).
struct VoiceTimingData: Codable {
    let silence_wait: Double; let recognize: Double; let audio_received: Double; let playing: Double; let total: Double
    /// The sounds the iPhone noticed in the turn and how sure it was (for tuning).
    var sounds: String? = nil
}

/// Space the files take on a Hermes instance.
public struct FilesUsage: Codable, Equatable, Sendable {
    public let bytes: Int
    public let count: Int
}

public struct ChatMessageData: Codable, Equatable {
    public let seq: Int
    public let role: String
    public let text: String
    /// Set when this saved message replaces a live reply (`chat.draft`) on the phone.
    public let draft_id: String?
    /// Change number: new when saved, new again when corrected (docs/chat-history.md).
    public let rev: Int?
    /// On user messages: the `chat.send` id, so the sending phone matches its own bubble.
    public let client_id: String?
    /// When the host saved it, UTC ISO 8601 (docs/agents-home.md).
    public let at: String?
    /// An approval or question card (docs/prompts.md).
    public let card: PromptCard?
    /// Photos and files with the message (docs/files.md).
    public let files: [ChatFile]?
    /// A voice note, and what Hermes heard (docs/voice.md).
    public let voice: VoiceDetails?
    public let transcript: String?
    /// Voice mode: the reply in the agent's Hermes voice, in parts (docs/voice.md §2).
    public let spoken: [ChatFile]?
    /// Voice mode: this reply is a voice note (tts | personality), and why its audio couldn't be made.
    public let voicing: String?
    public let voice_problem: String?
    /// The id its spoken parts arrive under, when it wasn't streamed.
    public let voice_key: String?
    /// Personality voice: what was said (the reply rewritten as speech); `text` is what was written.
    public let spoken_text: String?
    /// An artifact made or changed (a card), or the one a request is about (docs/artifacts.md).
    public let artifact: ArtifactCard?
    public let about: ArtifactCard?
    /// Comments on the artifact's lines, sent together (docs/artifacts.md, "Comments").
    public let review: [ReviewComment]?
    /// The Hermes conversation it belongs to (docs/chats.md).
    public let session: String?
    /// A Delegated card: the agent's delegated work as a tree (docs/delegation.md).
    public let delegation: HelpersTree?
    /// In a group chat: which agent said it (its profile id; docs/group-chats.md).
    public let speaker: String?

    public init(seq: Int, role: String, text: String, draft_id: String? = nil,
                rev: Int? = nil, client_id: String? = nil, at: String? = nil, card: PromptCard? = nil,
                files: [ChatFile]? = nil, voice: VoiceDetails? = nil, transcript: String? = nil,
                spoken: [ChatFile]? = nil, voicing: String? = nil, voice_problem: String? = nil,
                voice_key: String? = nil, spoken_text: String? = nil,
                artifact: ArtifactCard? = nil, about: ArtifactCard? = nil, review: [ReviewComment]? = nil,
                session: String? = nil, delegation: HelpersTree? = nil, speaker: String? = nil) {
        self.speaker = speaker
        self.delegation = delegation
        self.session = session
        self.review = review
        self.artifact = artifact
        self.about = about
        self.voice_key = voice_key
        self.spoken_text = spoken_text
        self.spoken = spoken
        self.voicing = voicing
        self.voice_problem = voice_problem
        self.files = files
        self.voice = voice
        self.transcript = transcript
        self.seq = seq
        self.role = role
        self.text = text
        self.draft_id = draft_id
        self.rev = rev
        self.client_id = client_id
        self.at = at
        self.card = card
    }

    /// `at` as a date (nil if absent or unreadable).
    public var date: Date? {
        at.flatMap { try? Date($0, strategy: .iso8601) }
    }
}

// MARK: - Delegation (docs/delegation.md)
/// Work an agent delegated (board handoffs to other agents, and sub-agents), as a tree.
public struct HelpersTree: Codable, Equatable, Hashable, Sendable {
    /// working | done
    public var status: String
    public var helpers: [Helper]

    public init(status: String, helpers: [Helper]) {
        self.status = status
        self.helpers = helpers
    }

    public var isWorking: Bool { status == "working" }
    /// Still waiting, working or blocked.
    public var openCount: Int { helpers.filter(\.isOpen).count }

    /// One piece of delegated work: a board task given to an agent, or a sub-agent copy.
    public struct Helper: Codable, Equatable, Hashable, Identifiable, Sendable {
        public let id: String
        /// The work that delegated this one (nil: the agent itself did).
        public let parent: String?
        public let goal: String
        /// Who does it (profile id); nil for a sub-agent copy of the agent.
        public let agent: String?
        /// The board task (board handoffs), and its board.
        public let task: String?
        public let board: String?
        /// waiting | working | finishing | blocked | done | failed | stopped | timed_out
        public var status: String
        /// What it's doing now ("Web search").
        public var doing: String?
        public var steps: Int
        public let started_at: String?
        public var ended_at: String?
        /// What it reported back.
        public var summary: String?

        public init(id: String, parent: String? = nil, goal: String, agent: String? = nil, task: String? = nil,
                    board: String? = nil, status: String, doing: String? = nil, steps: Int = 0,
                    started_at: String? = nil, ended_at: String? = nil, summary: String? = nil) {
            self.task = task
            self.board = board
            self.id = id
            self.parent = parent
            self.goal = goal
            self.agent = agent
            self.status = status
            self.doing = doing
            self.steps = steps
            self.started_at = started_at
            self.ended_at = ended_at
            self.summary = summary
        }

        public var isOpen: Bool { !["done", "failed", "stopped", "timed_out"].contains(status) }
        /// Something to stop: a sub-agent at work, or a board task whose worker is running.
        public var canStop: Bool { task == nil ? (status == "working" || status == "finishing") : status == "working" }
        public var startedDate: Date? { started_at.flatMap { try? Date($0, strategy: .iso8601) } }
        public var endedDate: Date? { ended_at.flatMap { try? Date($0, strategy: .iso8601) } }
    }

    /// One row of the tree: a helper and how deep it sits (0 = started by the agent itself).
    public struct Row: Identifiable, Equatable, Sendable {
        public let helper: Helper
        public let depth: Int
        public var id: String { helper.id }
    }

    /// Helpers in tree order: each followed by the helpers it started.
    public var rows: [Row] {
        let ids = Set(helpers.map(\.id))
        var out: [Row] = []
        func add(_ parent: String?, _ depth: Int) {
            for helper in helpers where helper.parent.flatMap({ ids.contains($0) ? $0 : nil }) == parent {
                out.append(Row(helper: helper, depth: depth))
                add(helper.id, depth + 1)
            }
        }
        add(nil, 0)
        return out
    }
}

public struct DelegationStopRequest: Codable, Equatable, Sendable {
    public let seq: Int
    public let helper_id: String?
}

public struct DelegationStopData: Codable, Equatable, Sendable {
    public let stopped: [String]
}

// MARK: - Slash commands (docs/slash-commands.md)
/// A command an agent can use, from Hermes' own lists.
public struct SlashCommand: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let description: String
    /// e.g. "[manual|smart|off]" or "<prompt>"
    public let args: String
    /// Fixed options for the first argument, e.g. ["manual", "smart", "off"].
    public let choices: [String]
    public let aliases: [String]
    /// "hermes", "plugin", "skill" or "quick"
    public let group: String
    public let category: String

    public init(name: String, description: String, args: String = "", choices: [String] = [],
                aliases: [String] = [], group: String = "hermes", category: String = "") {
        self.name = name
        self.description = description
        self.args = args
        self.choices = choices
        self.aliases = aliases
        self.group = group
        self.category = category
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        args = try c.decodeIfPresent(String.self, forKey: .args) ?? ""
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? "hermes"
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
    }

    /// Takes something after the name (an argument or an option).
    public var takesArguments: Bool { !args.isEmpty || !choices.isEmpty }
}

public struct CommandsListResult: Codable, Equatable {
    public let commands: [SlashCommand]
    public let fingerprint: String
}

public struct EmptyData: Codable, Equatable {
    public init() {}
}

// MARK: - Chat settings (docs/chat-settings.md)
/// A chat's current settings, as Hermes has them. Any part can be nil (couldn't be read).
public struct ChatSettingsData: Codable, Equatable, Sendable {
    public struct Model: Codable, Equatable, Sendable {
        public let model: String
        public let provider: String?
        /// Set for this chat only (else the agent's default).
        public let this_chat: Bool?
    }
    public struct Reasoning: Codable, Equatable, Sendable {
        public var effort: String
        public let this_chat: Bool?
    }
    public struct Personality: Codable, Equatable, Sendable {
        public struct Option: Codable, Equatable, Hashable, Sendable {
            public let name: String
            public let description: String?
        }
        public var current: String
        public let options: [Option]
    }
    public struct Usage: Codable, Equatable, Sendable {
        public let input_tokens: Int?
        public let output_tokens: Int?
        public let total_tokens: Int?
        public let context_tokens: Int?
        public let context_length: Int?
        public let cost_usd: Double?
    }

    public var model: Model?
    public var reasoning: Reasoning?
    public var show_reasoning: Bool?
    public var fast: String?
    public var yolo: Bool?
    public var personality: Personality?
    public var approvals: String?
    public var title: String?
    public var usage: Usage?

    public init(model: Model? = nil, reasoning: Reasoning? = nil, show_reasoning: Bool? = nil, fast: String? = nil,
                yolo: Bool? = nil, personality: Personality? = nil, approvals: String? = nil, title: String? = nil,
                usage: Usage? = nil) {
        self.model = model
        self.reasoning = reasoning
        self.show_reasoning = show_reasoning
        self.fast = fast
        self.yolo = yolo
        self.personality = personality
        self.approvals = approvals
        self.title = title
        self.usage = usage
    }

    /// The agent runs risky commands without asking: auto-approve in this chat, or approvals off.
    public var runsWithoutAsking: Bool { yolo == true || approvals == "off" }
}

/// A setting's new value: text or on/off.
public enum SettingValue: Codable, Equatable, Sendable {
    case text(String)
    case flag(Bool)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .flag(let value): try container.encode(value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) { self = .flag(flag) } else { self = .text(try container.decode(String.self)) }
    }
}

struct SettingChangeData: Codable { let key: String; let value: SettingValue }
struct SettingActionData: Codable { let action: String }
public struct SettingCommandResult: Codable, Equatable { public let command: String? }

// MARK: - Model picker details (docs/model-picker.md)
/// A model with its prices (USD per million tokens) and abilities, where known.
public struct CatalogModel: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String?
    public let maker: String?
    public let maker_name: String?
    public let created: Int?
    public let context: Int?
    public let input: Double?
    public let output: Double?
    public let cache_read: Double?
    public let free: Bool?
    public let reasoning: Bool?
    public let vision: Bool?

    public init(id: String, name: String? = nil, maker: String? = nil, maker_name: String? = nil, created: Int? = nil,
                context: Int? = nil, input: Double? = nil, output: Double? = nil, cache_read: Double? = nil,
                free: Bool? = nil, reasoning: Bool? = nil, vision: Bool? = nil) {
        self.id = id
        self.name = name
        self.maker = maker
        self.maker_name = maker_name
        self.created = created
        self.context = context
        self.input = input
        self.output = output
        self.cache_read = cache_read
        self.free = free
        self.reasoning = reasoning
        self.vision = vision
    }
}

public struct CatalogResult: Codable, Equatable {
    public let provider: String
    public let models: [CatalogModel]
    public let complete: Bool
}

/// A company hosting an OpenRouter model.
public struct ModelHost: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { tag }
    public let name: String
    public let tag: String
    public let input: Double?
    public let output: Double?
    public let cache_read: Double?
    public let discount: Double?
    public let context: Int?
    public let max_output: Int?
    public let quantization: String?
    public let uptime: Double?
    /// Where the company is based (ISO country code), and its policies.
    public var country: String? = nil
    public var privacy_url: String? = nil
    public var terms_url: String? = nil
}

public struct RoutingChoice: Codable, Equatable, Sendable {
    /// balanced, cheapest, fastest, one, prefer, only (or custom: set by hand in Hermes' config)
    public let mode: String
    public let hosts: [String]
    /// OpenRouter only uses hosts that don't store or train on your prompts.
    public let no_training: Bool?
    public let backup: String?

    public init(mode: String, hosts: [String] = [], no_training: Bool? = nil, backup: String? = nil) {
        self.mode = mode
        self.hosts = hosts
        self.no_training = no_training
        self.backup = backup
    }
}

public struct HostsResult: Codable, Equatable {
    public let model: String
    public let hosts: [ModelHost]
    public let routing: RoutingChoice
}

struct CatalogRequestData: Codable { let provider: String; let models: [String] }
struct ModelRequestData: Codable { let model: String }
struct RoutingRequestData: Codable { let model: String; let mode: String; let hosts: [String]; let no_training: Bool }

// MARK: - Approval and question cards (docs/prompts.md)
/// An agent asking for permission to do something risky, or asking you a question.
public struct PromptCard: Codable, Equatable, Sendable {
    /// `confirm`: a slash command such as /new asking to be confirmed. `model`: Hermes' model
    /// picker (/model). `choice`: Hermes' choice picker (/reasoning, /fast…).
    public enum Kind: String, Codable, Sendable { case approval, question, confirm, model, choice }

    /// One provider in the model picker, with the models Hermes can switch to.
    public struct ModelProvider: Codable, Equatable, Hashable, Sendable {
        public let slug: String
        public let name: String
        public let models: [String]
        public let isCurrent: Bool
        public let totalModels: Int
        public let modelLabels: [String: String]?

        enum CodingKeys: String, CodingKey {
            case slug, name, models
            case isCurrent = "is_current", totalModels = "total_models", modelLabels = "model_labels"
        }

        public init(slug: String, name: String, models: [String], isCurrent: Bool = false,
                    totalModels: Int? = nil, modelLabels: [String: String]? = nil) {
            self.slug = slug
            self.name = name
            self.models = models
            self.isCurrent = isCurrent
            self.totalModels = totalModels ?? models.count
            self.modelLabels = modelLabels
        }
    }

    /// One option in a choice picker.
    public struct Option: Codable, Equatable, Hashable, Sendable {
        public let value: String
        public let label: String
        public let isCurrent: Bool

        enum CodingKeys: String, CodingKey {
            case value, label
            case isCurrent = "is_current"
        }

        public init(value: String, label: String, isCurrent: Bool = false) {
            self.value = value
            self.label = label
            self.isCurrent = isCurrent
        }
    }

    public struct ChosenModel: Codable, Equatable, Sendable {
        public let model: String
        public let provider: String
        public let providerName: String?
        /// "session" or "global" when chosen explicitly.
        public let scope: String?

        enum CodingKeys: String, CodingKey {
            case model, provider, scope
            case providerName = "provider_name"
        }
    }

    public let kind: Kind
    public let id: String
    public var status: String
    /// Confirm: e.g. "Confirm /new".
    public let title: String?
    // Approval (and what a confirmation will do, in `description`)
    public let command: String?
    public let description: String?
    public let smartDenied: Bool?
    public let expiresAt: String?
    public var reason: String?
    // Question
    public let question: String?
    public let multiSelect: Bool?
    public var answer: String?
    /// Approval: the choices Hermes allows (once / session / always / deny). Question: its options.
    public let choices: [String]
    // Model picker
    public let currentModel: String?
    public let currentProvider: String?
    public let providers: [ModelProvider]?
    public var chosen: ChosenModel?
    // Choice picker (title in `title`)
    public let options: [Option]?

    enum CodingKeys: String, CodingKey {
        case kind, id, status, title, command, description, reason, question, answer, choices
        case smartDenied = "smart_denied", expiresAt = "expires_at", multiSelect = "multi_select"
        case currentModel = "current_model", currentProvider = "current_provider", providers, chosen, options
    }

    public init(kind: Kind, id: String, status: String = "pending", title: String? = nil, command: String? = nil,
                description: String? = nil, smartDenied: Bool? = nil, expiresAt: String? = nil,
                reason: String? = nil, question: String? = nil, multiSelect: Bool? = nil,
                answer: String? = nil, choices: [String] = [], currentModel: String? = nil,
                currentProvider: String? = nil, providers: [ModelProvider]? = nil, chosen: ChosenModel? = nil,
                options: [Option]? = nil) {
        self.currentModel = currentModel
        self.currentProvider = currentProvider
        self.providers = providers
        self.chosen = chosen
        self.options = options
        self.kind = kind
        self.id = id
        self.status = status
        self.title = title
        self.command = command
        self.description = description
        self.smartDenied = smartDenied
        self.expiresAt = expiresAt
        self.reason = reason
        self.question = question
        self.multiSelect = multiSelect
        self.answer = answer
        self.choices = choices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        title = try c.decodeIfPresent(String.self, forKey: .title)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        smartDenied = try c.decodeIfPresent(Bool.self, forKey: .smartDenied)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect)
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
        currentModel = try c.decodeIfPresent(String.self, forKey: .currentModel)
        currentProvider = try c.decodeIfPresent(String.self, forKey: .currentProvider)
        providers = try c.decodeIfPresent([ModelProvider].self, forKey: .providers)
        chosen = try c.decodeIfPresent(ChosenModel.self, forKey: .chosen)
        options = try c.decodeIfPresent([Option].self, forKey: .options)
    }

    /// Something only you can unblock (the agent is waiting): approvals, questions,
    /// confirmations. Pickers you opened yourself don't count.
    public var needsAttention: Bool { kind == .approval || kind == .question || kind == .confirm }

    public var isPending: Bool { status == "pending" }

    /// When Hermes stops waiting (approvals).
    public var expiryDate: Date? { expiresAt.flatMap { try? Date($0, strategy: .iso8601) } }

    /// Pending and not past its deadline.
    public func isOpen(now: Date = Date()) -> Bool {
        guard isPending else { return false }
        if let expiry = expiryDate, expiry <= now { return false }
        return true
    }
}

public struct PromptRespondData: Codable, Equatable {
    public let card_id: String
    public let choice: String?
    public let reason: String?
    public let answers: [String]?
    public let text: String?
    public let model: String?
    public let provider: String?
    public let confirmed: Bool?
    /// Model picker: "session" (this chat only) or "global" (the agent's default).
    public let scope: String?

    public init(card_id: String, choice: String? = nil, reason: String? = nil,
                answers: [String]? = nil, text: String? = nil, model: String? = nil,
                provider: String? = nil, confirmed: Bool? = nil, scope: String? = nil) {
        self.scope = scope
        self.card_id = card_id
        self.choice = choice
        self.reason = reason
        self.answers = answers
        self.text = text
        self.model = model
        self.provider = provider
        self.confirmed = confirmed
    }
}

public struct PromptRespondAckData: Codable, Equatable {
    public let card_id: String
    public let status: String
    /// With `needs_confirmation`: why Hermes wants you to confirm (e.g. an expensive model).
    public let message: String?
}

// MARK: - Chat history and read state (docs/chat-history.md)
/// A page of one agent's messages older than `before_seq` (all, when nil).
public struct HistoryFetchData: Codable, Equatable {
    public let before_seq: Int?
    public let limit: Int
}

public struct HistoryPageData: Codable, Equatable {
    public let messages: [ChatMessageData]
    public let has_more: Bool
}

/// Both directions: "read up to `seq`" for the envelope's agent.
public struct ChatReadData: Codable, Equatable {
    public let seq: Int
}

// MARK: - Streaming (docs/streaming.md); neither is stored or replayed by the host
/// A reply being written: the full text so far. Empty text = drop the live bubble.
public struct ChatDraftData: Codable, Equatable {
    public let draft_id: String
    public let text: String
    /// In a group chat: which agent is writing it.
    public let speaker: String?
}

/// Whether an agent is working, and on what ("Searching the web…") when Hermes knows.
public struct ChatTypingData: Codable, Equatable {
    public let active: Bool
    public let status: String?
    /// In a group chat: which agent is working.
    public let speaker: String?
}

// MARK: - Group chats (docs/group-chats.md)
/// A group chat: a name and member agents. Its chat is `group:<group_id>`.
public struct GroupData: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let group_id: String
    public let name: String
    public let members: [String]
    public let created_at: String?

    public init(group_id: String, name: String, members: [String], created_at: String? = nil) {
        self.group_id = group_id
        self.name = name
        self.members = members
        self.created_at = created_at
    }

    public var id: String { group_id }
    /// The group's chat: used where an agent's id would be.
    public var key: String { GroupData.keyPrefix + group_id }
    public static let keyPrefix = "group:"
    public static func isKey(_ id: String) -> Bool { id.hasPrefix(keyPrefix) }
}

struct GroupsListData: Codable { let groups: [GroupData] }
struct GroupResult: Codable { let group: GroupData }
struct GroupIdResult: Codable { let group_id: String }
struct GroupCreateRequest: Codable { let name: String; let members: [String] }
struct GroupUpdateRequest: Codable { let group_id: String; let name: String?; let members: [String]? }
struct GroupDeleteRequest: Codable { let group_id: String }
struct GroupStartRequest: Codable { let from: String; let members: [String] }
struct GroupIdRequest: Codable { let group_id: String }

/// A group's members' sides as Hermes sees them: model, its title, context, tokens and cost.
public struct GroupDetails: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Sendable, Identifiable {
        public let profile_id: String
        public let model: String?
        public let title: String?
        public let usage: ChatSettingsData.Usage?
        public var id: String { profile_id }
    }
    public struct Totals: Codable, Equatable, Sendable {
        public let cost_usd: Double?
        public let input_tokens: Int?
        public let output_tokens: Int?
    }
    public let members: [Member]
    public let totals: Totals
}
struct GroupStartResult: Codable { let group: GroupData; let created: Bool }

// MARK: - Unpairing ("Forget Host")
/// Sent on a fresh socket without `hello`: carries its own credentials.
public struct DeviceUnpairData: Codable, Equatable {
    public let device_id: String
    public let device_token: String

    public init(device_id: String, device_token: String) {
        self.device_id = device_id
        self.device_token = device_token
    }
}

public struct DeviceUnpairAckData: Codable, Equatable {
    public let status: String
    public let device_id: String
}

// MARK: - Standard Error Envelope Payload
public struct ErrorData: Codable, Equatable {
    public let code: String
    public let reason: String
    public let recoverable: Bool?

    public init(code: String, reason: String, recoverable: Bool? = nil) {
        self.code = code
        self.reason = reason
        self.recoverable = recoverable
    }
}

// MARK: - Agent lifecycle (docs/agent-lifecycle.md)
public struct ProfileCreateData: Codable, Equatable {
    public let name: String
    public let description: String?
}

public struct ProfileCreateAckData: Codable, Equatable {
    public let status: String
    public let profile: ProfileData
}

/// `confirm` must equal `profile_id`: the host refuses a delete without it.
public struct ProfileDeleteData: Codable, Equatable {
    public let profile_id: String
    public let confirm: String
}

public struct ProfileDeleteAckData: Codable, Equatable {
    public let status: String
    public let profile_id: String
    /// Where the host saved the backup, relative to the Hermes folder.
    public let backup: String
}

/// Broadcast to every phone when agents are created or deleted.
/// `instance.rename` (Client -> Host) and its result / `instance.changed` (Host -> Client)
/// (docs/multiple-instances.md).
struct InstanceRenameData: Codable { let name: String }
public struct InstanceNameData: Codable, Equatable {
    public let instance_name: String
    /// What the agents call you (docs/your-name.md); absent from older plugins.
    public let user_name: String?
}
struct UserNameSetData: Codable { let name: String }
struct UserNameData: Codable { let user_name: String }

public struct ProfilesChangedData: Codable, Equatable {
    public let profiles: [ProfileData]
}

/// Mirrors the host's rule ('Research Assistant' -> 'research-assistant'), so the phone can
/// show the id an agent will get. The host decides.
public enum ProfileNaming {
    public static func id(for name: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash && !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        var trimmed = String(slug.prefix(64))
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        return trimmed
    }
}


// MARK: - Artifacts (docs/artifacts.md)

/// An artifact as a chat card or a list row.
public struct ArtifactCard: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let artifact_id: String
    public let title: String
    /// html | markdown | code | svg | text
    public let kind: String
    public let language: String?
    public let version: Int
    /// On cards: created | updated | edited
    public let action: String?
    public let updated_at: String?
    /// On cards of code, documents, text and diagrams: their first lines (the card's preview).
    public let excerpt: String?
    public var id: String { artifact_id }

    public init(artifact_id: String, title: String, kind: String, language: String? = nil, version: Int,
                action: String? = nil, updated_at: String? = nil, excerpt: String? = nil) {
        self.excerpt = excerpt
        self.artifact_id = artifact_id
        self.title = title
        self.kind = kind
        self.language = language
        self.version = version
        self.action = action
        self.updated_at = updated_at
    }
}

public struct ArtifactRef: Codable, Equatable, Sendable { public let artifact_id: String }

public struct ArtifactVersionInfo: Codable, Equatable, Identifiable, Sendable {
    public let version: Int
    /// agent | user
    public let author: String
    public let note: String?
    public let created_at: String?
    public let size: Int?
    public var id: Int { version }
}

/// An artifact opened: one version's content, and every version.
public struct ArtifactDetail: Codable, Equatable, Sendable {
    public let artifact_id: String
    public let title: String
    public let kind: String
    public let language: String?
    public let version: Int
    public let shown_version: Int
    public let content: String
    public let versions: [ArtifactVersionInfo]

    public var card: ArtifactCard {
        ArtifactCard(artifact_id: artifact_id, title: title, kind: kind, language: language, version: version)
    }
}

struct ArtifactsListResult: Codable { let artifacts: [ArtifactCard] }
struct ArtifactGetData: Codable { let artifact_id: String; let version: Int? }
struct ArtifactSaveData: Codable { let artifact_id: String; let content: String; let base_version: Int; let note: String? }
struct ArtifactSaveResult: Codable { let artifact: ArtifactCard }
struct ArtifactChangedData: Codable { let artifact: ArtifactCard }


/// A comment on one or more lines of an artifact (docs/artifacts.md, "Comments").
public struct ReviewComment: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var line_start: Int
    public var line_end: Int
    /// The lines it's about, as they read when it was written.
    public var quote: String
    public var comment: String
    /// Only on the phone, while it's a draft (not sent).
    public var id: String

    enum CodingKeys: String, CodingKey { case line_start, line_end, quote, comment }

    public init(lineStart: Int, lineEnd: Int, quote: String, comment: String, id: String = UUID().uuidString) {
        line_start = lineStart
        line_end = lineEnd
        self.quote = quote
        self.comment = comment
        self.id = id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        line_start = try c.decode(Int.self, forKey: .line_start)
        line_end = try c.decodeIfPresent(Int.self, forKey: .line_end) ?? line_start
        quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
        comment = try c.decode(String.self, forKey: .comment)
        id = UUID().uuidString
    }

    /// "Line 12" or "Lines 12–14".
    public var lines: String { line_start == line_end ? "Line \(line_start)" : "Lines \(line_start)–\(line_end)" }
}

/// Draft comments, kept on this phone until they're sent (with their own ids).
struct ReviewDraft: Codable {
    var comments: [StoredComment]
    struct StoredComment: Codable { let id: String; let start: Int; let end: Int; let quote: String; let comment: String }

    init(_ comments: [ReviewComment]) {
        self.comments = comments.map { StoredComment(id: $0.id, start: $0.line_start, end: $0.line_end, quote: $0.quote, comment: $0.comment) }
    }

    var reviewComments: [ReviewComment] {
        comments.map { ReviewComment(lineStart: $0.start, lineEnd: $0.end, quote: $0.quote, comment: $0.comment, id: $0.id) }
    }
}


// MARK: - Past chats (docs/chats.md)

/// One of an agent's conversations, as Hermes keeps them.
public struct ChatSessionInfo: Codable, Equatable, Identifiable, Sendable {
    public let session_id: String
    public let title: String?
    public let preview: String?
    public let started_at: Double?
    public let last_at: Double?
    public let messages: Int
    public let current: Bool
    /// Searching: the words that matched.
    public let match: String?
    public var id: String { session_id }

    public var name: String { title ?? preview ?? "Untitled chat" }
    public var lastDate: Date? { (last_at ?? started_at).map { Date(timeIntervalSince1970: $0) } }
}

public struct ChatSessionsData: Codable, Equatable, Sendable {
    public let current: String?
    public let chats: [ChatSessionInfo]
}

struct ChatSessionRef: Codable { let session_id: String }
struct ChatsQuery: Codable { let query: String? }
struct ChatHistoryResult: Codable { let session_id: String; let messages: [ChatMessageData] }

// MARK: - Board (docs/kanban.md, protocol.md §20)

/// A task on Hermes' board, as a card (with more filled in when opened).
public struct KanbanCard: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var status: String
    public var assignee: String?
    public var priority: Int
    public let created_at: Double?
    public var started_at: Double?
    public var completed_at: Double?
    /// While running: when this run started.
    public var running_since: Double?
    public var summary: String?
    /// Unfinished tasks it waits on.
    public var waits_on: Int
    public var comments: Int
    // Opened only:
    public var body: String?
    public var result: String?
    public var failures: Int?
    public var last_error: String?

    public init(id: String, title: String, status: String, assignee: String? = nil, priority: Int = 0,
                created_at: Double? = nil, started_at: Double? = nil, completed_at: Double? = nil,
                running_since: Double? = nil, summary: String? = nil, waits_on: Int = 0, comments: Int = 0) {
        self.id = id
        self.title = title
        self.status = status
        self.assignee = assignee
        self.priority = priority
        self.created_at = created_at
        self.started_at = started_at
        self.completed_at = completed_at
        self.running_since = running_since
        self.summary = summary
        self.waits_on = waits_on
        self.comments = comments
    }
}

public struct KanbanBoardInfo: Codable, Equatable, Identifiable, Sendable {
    public let slug: String
    public let name: String
    public let icon: String?
    public let current: Bool
    public var id: String { slug }
}

public struct KanbanColumn: Codable, Equatable, Sendable {
    public let key: String
    public let label: String
}

public struct KanbanBoardResult: Codable, Equatable, Sendable {
    public let board: String
    public let boards: [KanbanBoardInfo]
    public let columns: [KanbanColumn]
    /// Where a task may be moved from each status (Hermes' rules).
    public let moves: [String: [String]]
    public var tasks: [KanbanCard]
}

public struct KanbanComment: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let author: String
    public let body: String
    public let created_at: Double
}

public struct KanbanRun: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let profile: String?
    public let status: String
    public let outcome: String?
    public let started_at: Double?
    public let ended_at: Double?
    public let summary: String?
    public let error: String?
}

public struct KanbanLinked: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let status: String
}

public struct KanbanEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let kind: String
    public let created_at: Double
    public let summary: String
}

public struct KanbanTaskResult: Codable, Equatable, Sendable {
    public let board: String
    public let task: KanbanCard
    public let comments: [KanbanComment]
    public let runs: [KanbanRun]
    public let parents: [KanbanLinked]
    public let children: [KanbanLinked]
    public let events: [KanbanEvent]
}

public struct KanbanChangeResult: Codable, Equatable, Sendable {
    public let board: String
    public let task: KanbanCard
}

public struct KanbanChangedData: Codable, Equatable, Sendable {
    public let board: String
    public let task_ids: [String]
}

struct KanbanBoardRequest: Codable { let board: String?; let archived: Bool }
struct KanbanTaskRequest: Codable { let board: String?; let task_id: String }
struct KanbanCreateData: Codable {
    let board: String?; let title: String; let body: String?; let assignee: String?
    let priority: Int; let parents: [String]; let triage: Bool
}
struct KanbanEditData: Codable { let board: String?; let task_id: String; let title: String; let body: String; let priority: Int }
struct KanbanMoveData: Codable { let board: String?; let task_id: String; let status: String; let note: String? }
struct KanbanAssignData: Codable {
    let board: String?; let task_id: String; let assignee: String?
    // `assignee: null` means nobody: sent even when empty.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(board, forKey: .board)
        try c.encode(task_id, forKey: .task_id)
        try c.encode(assignee, forKey: .assignee)
    }
}
struct KanbanCommentData: Codable { let board: String?; let task_id: String; let body: String }
struct KanbanLinkData: Codable { let board: String?; let task_id: String; let parent_id: String; let remove: Bool }

// MARK: - Schedules (docs/scheduler.md, protocol.md §21)

/// When a Hermes cron job runs, as Hermes keeps it.
public struct ScheduleWhen: Codable, Equatable, Sendable {
    /// cron, interval or once.
    public let kind: String?
    public let display: String
    public let expr: String?
    public let minutes: Int?
    public let run_at: String?

    public init(kind: String?, display: String, expr: String? = nil, minutes: Int? = nil, run_at: String? = nil) {
        self.kind = kind
        self.display = display
        self.expr = expr
        self.minutes = minutes
        self.run_at = run_at
    }
}

public struct ScheduleRepeat: Codable, Equatable, Sendable {
    public let times: Int?
    public let completed: Int
}

/// One agent's scheduled job (a Hermes cron job).
public struct ScheduleJob: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let profile_id: String
    public let name: String?
    public let prompt: String
    public let schedule: ScheduleWhen
    public let state: String
    public let enabled: Bool
    public let next_run_at: String?
    public let last_run_at: String?
    public let last_status: String?
    public let last_error: String?
    public let deliver: String
    public let `repeat`: ScheduleRepeat
    public let model: String?
    public let skills: [String]
    /// Runs a script rather than (or before) the agent: shown, not editable here.
    public let script: Bool

    public var isPaused: Bool { state == "paused" || !enabled }
    public var title: String {
        if let name, !name.isEmpty { return name }
        let first = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return first.isEmpty ? "Untitled schedule" : String(first.prefix(80))
    }
}

public struct SchedulesListResult: Codable, Equatable, Sendable { public let jobs: [ScheduleJob] }
public struct ScheduleJobResult: Codable, Equatable, Sendable { public let job: ScheduleJob }

public struct SchedulePreview: Codable, Equatable, Sendable {
    public let kind: String?
    public let display: String
    public let expr: String?
    public let minutes: Int?
    public let run_at: String?
    public let next: [String]

    public var when: ScheduleWhen { ScheduleWhen(kind: kind, display: display, expr: expr, minutes: minutes, run_at: run_at) }
}

public struct ScheduleRun: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let started_at: Double?
    public let ended_at: Double?
    /// ok, failed or running.
    public let status: String
    public let title: String?
}

public struct ScheduleRunsResult: Codable, Equatable, Sendable { public let runs: [ScheduleRun] }
public struct ScheduleOutputResult: Codable, Equatable, Sendable { public let text: String }
struct ScheduleDeleteResult: Codable { let job_id: String }

struct SchedulePreviewData: Codable { let schedule: String }
struct ScheduleDraftData: Codable { let description: String }

/// A cron job drafted from the user's words by Hermes' model; nothing is created until they confirm.
public struct ScheduleDraft: Codable, Equatable, Sendable {
    public let name: String?
    public let prompt: String
    public let schedule: String
    public let preview: SchedulePreview
}
struct ScheduleJobRef: Codable { let job_id: String }
struct ScheduleOutputData: Codable { let job_id: String; let run_id: String }
public struct ScheduleCreateData: Codable, Equatable {
    public var name: String?
    public var prompt: String
    public var schedule: String
    public var deliver: String?
    public var `repeat`: Int?
    public var model: String?
    public var skills: [String]?
}

/// What to change; a field left nil is kept. `repeat`/`model` can be cleared on purpose.
public struct ScheduleChanges: Codable, Equatable {
    public var name: String?
    public var prompt: String?
    public var schedule: String?
    public var deliver: String?
    public var skills: [String]?
    /// Set: change it (nil inside = forever / the agent's own model).
    public var repeatTimes: Int??
    public var model: String??

    public init(name: String? = nil, prompt: String? = nil, schedule: String? = nil, deliver: String? = nil,
                skills: [String]? = nil, repeatTimes: Int?? = nil, model: String?? = nil) {
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.deliver = deliver
        self.skills = skills
        self.repeatTimes = repeatTimes
        self.model = model
    }

    enum CodingKeys: String, CodingKey { case name, prompt, schedule, deliver, skills, repeatTimes = "repeat", model }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encodeIfPresent(schedule, forKey: .schedule)
        try c.encodeIfPresent(deliver, forKey: .deliver)
        try c.encodeIfPresent(skills, forKey: .skills)
        if let repeatTimes { try c.encode(repeatTimes, forKey: .repeatTimes) }
        if let model { try c.encode(model, forKey: .model) }
    }

    public var isEmpty: Bool {
        name == nil && prompt == nil && schedule == nil && deliver == nil && skills == nil && repeatTimes == nil && model == nil
    }
}

struct ScheduleUpdateData: Codable { let job_id: String; let changes: ScheduleChanges }
