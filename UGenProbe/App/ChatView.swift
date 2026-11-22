import SwiftUI
import UGenKit

struct ChatTurn: Identifiable, Codable {
    var id = UUID()
    let fromUser: Bool
    var text: String
    var seconds: Double?
    var tokens: Int?
}

/// One saved conversation.
struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title: String
    var model: String
    var instructions: String
    var turns: [ChatTurn]
    var updated: Date
}

/// Conversations kept on the iPad between launches.
@MainActor
final class ChatHistory: ObservableObject {
    @Published var conversations: [Conversation] = []

    private static var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("chats.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = saved
        }
    }

    func save(_ conversation: Conversation) {
        guard !conversation.turns.isEmpty else { return }
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        conversations.sort { $0.updated > $1.updated }
        persist()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(conversations) { try? data.write(to: Self.file, options: .atomic) }
    }
}

/// A conversation with a language model running on the stick.
struct ChatView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var history = ChatHistory()
    @AppStorage("chat.model") private var modelName = StudioModel.chatModelNames[0]
    @AppStorage("chat.system") private var systemPrompt = "You are a helpful assistant."
    @AppStorage("chat.temperature") private var temperature = 0.7
    @AppStorage("chat.maxTokens") private var maxTokens = 512
    @State private var conversation = Conversation(title: "New chat", model: "", instructions: "", turns: [], updated: Date())
    @State private var draft = ""
    @State private var generating: Task<Void, Never>?
    @State private var note = ""
    @State private var contextStarted = false
    @State private var contextUsed: Int?
    @State private var showSettings = false
    @FocusState private var typing: Bool

    private let starters = [
        "Explain how a neural network accelerator differs from a GPU.",
        "Write a short checklist for setting up a home lab.",
        "Give me three ideas for a weekend coding project.",
        "Summarise the pros and cons of running AI models locally.",
    ]

    private var modelReady: Bool { studio.chatModelName == modelName && studio.chatModel != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            composer
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(conversation.turns.isEmpty ? "Chat" : conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    if history.conversations.isEmpty { Text("No saved chats yet") }
                    ForEach(history.conversations) { saved in
                        Button { open(saved) } label: {
                            Label(saved.title, systemImage: saved.id == conversation.id ? "checkmark" : "bubble.left")
                        }
                    }
                    if !history.conversations.isEmpty {
                        Divider()
                        Button("Delete this chat", role: .destructive) { deleteCurrent() }.disabled(conversation.turns.isEmpty)
                    }
                } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                .disabled(generating != nil)
                Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                    .popover(isPresented: $showSettings) { settings }
                Button { newChat() } label: { Label("New chat", systemImage: "square.and.pencil") }
                    .disabled(generating != nil || conversation.turns.isEmpty)
            }
        }
        .onChange(of: modelName) { _, _ in contextStarted = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Model", selection: $modelName) {
                ForEach(StudioModel.chatModelNames, id: \.self) { name in
                    Text(studio.installed.contains(name) ? name : "\(name) (not on this \(StudioModel.deviceKind))").tag(name)
                }
            }
            .pickerStyle(.menu).fixedSize()
            .disabled(generating != nil)
            Chip(text: modelReady ? "On the stick" : "Loads on first message", systemImage: modelReady ? "checkmark.circle.fill" : "arrow.down.circle",
                 tint: modelReady ? .green : .secondary)
            Spacer()
            if let contextUsed { Chip(text: "\(contextUsed) / 2048 tokens of memory used", systemImage: "memorychip") }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if conversation.turns.isEmpty { emptyState }
                    ForEach(conversation.turns) { turn in
                        MessageRow(turn: turn, modelName: conversation.model.isEmpty ? modelName : conversation.model,
                                   working: generating != nil && turn.id == conversation.turns.last?.id)
                            .id(turn.id)
                    }
                    if !note.isEmpty {
                        Label(note, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: conversation.turns.last?.text) { _, _ in
                if let last = conversation.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                LogoMark(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Private chat on the stick").font(.title2.weight(.semibold))
                    Text("\(modelName) answers on the UGen300. Nothing is sent to the internet.").font(.callout).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(starters, id: \.self) { starter in
                    Button { draft = starter; send() } label: {
                        Text(starter).font(.callout).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 30)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message \(modelName)", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($typing)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.secondary.opacity(0.25)))
                .onSubmit { send() }
            if generating != nil {
                Button { generating?.cancel() } label: { Image(systemName: "stop.fill").frame(width: 22, height: 22) }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
            } else {
                Button { send() } label: { Image(systemName: "arrow.up").fontWeight(.bold).frame(width: 22, height: 22) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.large)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var settings: some View {
        Form {
            Section("Instructions for the model") {
                TextField("Instructions", text: $systemPrompt, axis: .vertical).lineLimit(2...6)
                Text("Applies from the next new chat.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Answers") {
                VStack(alignment: .leading) {
                    Text(String(format: "Creativity (temperature): %.1f", temperature))
                    Slider(value: $temperature, in: 0...1.5, step: 0.1)
                }
                Stepper("Up to \(maxTokens) tokens per answer", value: $maxTokens, in: 64...1024, step: 64)
            }
        }
        .frame(width: 420, height: 380)
    }

    private func open(_ saved: Conversation) {
        conversation = saved
        if StudioModel.chatModelNames.contains(saved.model) { modelName = saved.model }
        contextStarted = false  // the stick does not have this conversation; it is replayed on the next message
        contextUsed = nil
        note = ""
    }

    private func deleteCurrent() {
        history.delete(conversation.id)
        newChat()
    }

    private func newChat() {
        conversation = Conversation(title: "New chat", model: "", instructions: "", turns: [], updated: Date())
        note = ""
        contextStarted = false
        contextUsed = nil
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, generating == nil else { return }
        draft = ""
        note = ""
        if conversation.turns.isEmpty {
            conversation.title = String(text.prefix(48))
            conversation.model = modelName
            conversation.instructions = systemPrompt
        }
        let earlier = conversation.turns
        conversation.turns.append(ChatTurn(fromUser: true, text: text))
        conversation.turns.append(ChatTurn(fromUser: false, text: ""))
        let answerIndex = conversation.turns.count - 1
        let name = modelName
        let instructions = conversation.instructions

        generating = Task {
            defer {
                generating = nil
                conversation.updated = Date()
                if conversation.turns.last?.text.isEmpty == true { conversation.turns[answerIndex].text = "(no answer)" }
                history.save(conversation)
            }
            do {
                // The stick keeps the conversation; a freshly loaded model, or a reopened chat, has none.
                let wasLoaded = studio.chatModelName == name && studio.chatModel != nil
                let model = try await studio.chat(named: name)
                if !wasLoaded { contextStarted = false }
                var messages: [ChatMessage] = []
                if !contextStarted {
                    try await model.clearContext()
                    let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { messages.append(.system(trimmed)) }
                    for turn in earlier where !turn.text.isEmpty {
                        messages.append(turn.fromUser ? .user(turn.text) : .assistant(turn.text))
                    }
                }
                messages.append(.user(text))
                contextStarted = true

                var parameters = model.defaultParameters
                parameters.temperature = Float(temperature)
                parameters.doSample = temperature > 0
                parameters.maxGeneratedTokens = UInt32(maxTokens)

                let clock = ContinuousClock()
                let start = clock.now
                var pieces = 0
                for try await piece in model.generate(messages: messages, parameters: parameters) {
                    conversation.turns[answerIndex].text += piece
                    pieces += 1
                }
                let elapsed = clock.now - start
                conversation.turns[answerIndex].seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                conversation.turns[answerIndex].tokens = pieces
                contextUsed = try? await model.contextUsage()
            } catch is CancellationError {
            } catch {
                studio.fail(error)
                note = "\(error)"
                contextStarted = false
            }
        }
    }
}

/// One message: who said it, the text with formatting, and for answers the speed and a copy button.
private struct MessageRow: View {
    let turn: ChatTurn
    let modelName: String
    let working: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if turn.fromUser {
                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary).frame(width: 32)
            } else {
                LogoMark(size: 30).frame(width: 32)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(turn.fromUser ? "You" : modelName).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                if turn.text.isEmpty {
                    if working { ProgressView().controlSize(.small) }
                } else if turn.fromUser {
                    Text(turn.text).textSelection(.enabled)
                } else {
                    FormattedText(text: turn.text)
                }
                if !turn.fromUser, !turn.text.isEmpty, !working {
                    HStack(spacing: 8) {
                        if let seconds = turn.seconds, let tokens = turn.tokens, seconds > 0 {
                            Chip(text: String(format: "%.1f tokens/s", Double(tokens) / seconds), systemImage: "speedometer")
                            Chip(text: String(format: "%.1f s", seconds), systemImage: "timer")
                        }
                        Button { UIPasteboard.general.string = turn.text } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
