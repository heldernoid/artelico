import SwiftUI

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

/// Conversations kept on this device between launches.
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

/// A conversation with a GGUF language model running on this device (llama.cpp, GPU).
struct ChatView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var history = ChatHistory()
    @AppStorage("chat.model") private var modelName = GGUFModel.catalog[0].id
    /// Qwen3 "thinks" out loud before answering unless asked not to; off by default.
    @AppStorage("chat.thinking") private var thinking = false
    @AppStorage("chat.system") private var systemPrompt = "You are a helpful assistant."
    @AppStorage("chat.temperature") private var temperature = 0.7
    @AppStorage("chat.maxTokens") private var maxTokens = 512
    @State private var conversation = Conversation(title: "New chat", model: "", instructions: "", turns: [], updated: Date())
    @State private var draft = ""
    @State private var generating: Task<Void, Never>?
    @State private var note = ""
    @State private var contextUsed: Int?
    @State private var showSettings = false
    @State private var engine: LlamaEngine?
    @FocusState private var typing: Bool

    private let starters = [
        "Explain how a neural network accelerator differs from a GPU.",
        "Write a short checklist for setting up a home lab.",
        "Give me three ideas for a weekend coding project.",
        "Summarise the pros and cons of running AI models locally.",
    ]

    private var model: GGUFModel? { studio.languageModels.first { $0.id == modelName } }
    private var modelTitle: String { model?.title ?? modelName }
    private var modelReady: Bool { studio.llmName == modelName && studio.llm != nil }

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
        .onAppear {
            if model == nil { modelName = GGUFModel.catalog[0].id }
            // `-chat "<question>" [-chatmodel <file>]` sends one message at launch (testing from the Mac).
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "-chatmodel"), index + 1 < arguments.count { modelName = arguments[index + 1] }
            if let index = arguments.firstIndex(of: "-chat"), index + 1 < arguments.count, conversation.turns.isEmpty, generating == nil {
                draft = arguments[index + 1]
                send()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Model", selection: $modelName) {
                ForEach(studio.languageModels) { item in
                    Text(studio.isDownloaded(item) ? item.title : "\(item.title) (\(String(format: "%.1f", Double(item.totalMegabytes) / 1000)) GB download)").tag(item.id)
                }
            }
            .pickerStyle(.menu).fixedSize()
            .disabled(generating != nil)
            if let progress = studio.llmDownloads[modelName] {
                ProgressView(value: progress).frame(width: 120)
                Text(studio.llmDownloadInfo[modelName] ?? "\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            } else if let model {
                Chip(text: modelReady ? "Loaded" : (studio.isDownloaded(model) ? "Loads on first message" : "Downloads on first message"),
                     systemImage: modelReady ? "checkmark.circle.fill" : "arrow.down.circle", tint: modelReady ? .green : .secondary)
            }
            Spacer()
            if let contextUsed { Chip(text: "\(contextUsed) / 4096 tokens", systemImage: "memorychip") }
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
                        MessageRow(turn: turn, modelName: studio.languageModels.first { $0.id == (conversation.model.isEmpty ? modelName : conversation.model) }?.title ?? modelTitle,
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
                    Text("Private chat on this \(StudioModel.deviceKind)").font(.title2.weight(.semibold))
                    Text("\(modelTitle) runs on this \(StudioModel.deviceKind)'s own chips. Your messages are not sent anywhere.").font(.callout).foregroundStyle(.secondary)
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
            TextField("Message \(modelTitle)", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($typing)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.secondary.opacity(0.25)))
                .onSubmit { send() }
            if generating != nil {
                Button { generating?.cancel(); if let engine { Task { await engine.cancel() } } } label: { Image(systemName: "stop.fill").frame(width: 22, height: 22) }
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
                Stepper("Up to \(maxTokens) tokens per answer", value: $maxTokens, in: 64...2048, step: 64)
                Toggle("Let Qwen3 think before answering", isOn: $thinking)
            }
            if let model {
                Section("Model") {
                    LabeledContent("Licence", value: model.license)
                    if !model.note.isEmpty { Text(model.note).font(.caption).foregroundStyle(.secondary) }
                    if studio.isDownloaded(model) {
                        Button("Delete \(model.title) from this \(StudioModel.deviceKind)", role: .destructive) { studio.deleteLanguageModel(model) }
                            .disabled(generating != nil)
                    }
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 420, minHeight: 380, idealHeight: 480)
    }

    private func open(_ saved: Conversation) {
        conversation = saved
        if studio.languageModels.contains(where: { $0.id == saved.model }) { modelName = saved.model }
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
        guard let chosen = model else { return }
        let instructions = conversation.instructions

        generating = Task {
            defer {
                generating = nil
                engine = nil
                conversation.updated = Date()
                if conversation.turns.last?.text.isEmpty == true { conversation.turns[answerIndex].text = "(no answer)" }
                history.save(conversation)
                #if DEBUG
                // Tests started with -chat read the answer from the app's standard output.
                if CommandLine.arguments.contains("-chat") { FileHandle.standardError.write(Data("CHAT ANSWER [\(modelName)]: \(conversation.turns[answerIndex].text) | \(note)\n".utf8)) }
                #endif
            }
            do {
                // Keep the screen on while downloading, loading and answering (a lock would suspend the app).
                UIApplication.shared.isIdleTimerDisabled = true
                defer { UIApplication.shared.isIdleTimerDisabled = false }
                let llm = try await studio.languageModel(chosen)
                engine = llm
                // The whole conversation is sent each time; the engine starts from a clean context.
                var messages: [LlamaEngine.Message] = []
                let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { messages.append(.init(role: "system", content: trimmed)) }
                for turn in earlier where !turn.text.isEmpty {
                    messages.append(.init(role: turn.fromUser ? "user" : "assistant", content: turn.fromUser ? turn.text : visibleAnswer(turn.text)))
                }
                let isQwen3 = chosen.title.hasPrefix("Qwen3")
                messages.append(.init(role: "user", content: isQwen3 && !thinking ? text + " /no_think" : text))

                var parameters = LlamaEngine.Parameters()
                parameters.temperature = Float(temperature)
                parameters.maxTokens = maxTokens

                // The answer streams in piece by piece; the stream ends when generation ends (or Stop).
                let (pieces, sink) = AsyncStream<String>.makeStream()
                let work = Task.detached {
                    defer { sink.finish() }
                    return try await llm.generate(messages, parameters: parameters) { sink.yield($0) }
                }
                for await piece in pieces {
                    conversation.turns[answerIndex].text += piece
                }
                let stats = try await work.value
                conversation.turns[answerIndex].seconds = stats.generationSeconds
                conversation.turns[answerIndex].tokens = stats.generatedTokens
                contextUsed = stats.promptTokens + stats.generatedTokens
                saveForTesting(stats: stats)
            } catch is CancellationError {
            } catch {
                studio.fail(error)
                note = "\(error)"
                saveForTesting(stats: nil)
            }
        }
    }

    /// Writes the last answer to Documents/chat-result.txt so it can be read from the Mac without a screenshot.
    private func saveForTesting(stats: LlamaEngine.Stats?) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var lines = ["model: \(modelTitle)"]
        if let stats {
            lines.append(String(format: "prompt %d tokens in %.2f s; answer %d tokens in %.2f s = %.1f tokens/s",
                                stats.promptTokens, stats.promptSeconds, stats.generatedTokens, stats.generationSeconds, stats.tokensPerSecond))
        }
        if !note.isEmpty { lines.append("error: \(note)") }
        lines.append(visibleAnswer(conversation.turns.last?.text ?? ""))
        try? lines.joined(separator: "\n").write(to: documents.appendingPathComponent("chat-result.txt"), atomically: true, encoding: .utf8)
    }
}

/// The answer without the model's "thinking" (Qwen3 writes it between <think> and </think>).
func visibleAnswer(_ text: String) -> String {
    var result = text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
    if let open = result.range(of: "<think>") { result = String(result[..<open.lowerBound]) }   // still thinking
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
                } else if visibleAnswer(turn.text).isEmpty {
                    if working { Label("Thinking…", systemImage: "ellipsis").font(.callout).foregroundStyle(.secondary) }
                } else {
                    FormattedText(text: visibleAnswer(turn.text))
                }
                if !turn.fromUser, !turn.text.isEmpty, !working {
                    HStack(spacing: 8) {
                        if let seconds = turn.seconds, let tokens = turn.tokens, seconds > 0 {
                            Chip(text: String(format: "%.1f tokens/s", Double(tokens) / seconds), systemImage: "speedometer")
                            Chip(text: String(format: "%.1f s", seconds), systemImage: "timer")
                        }
                        Button { UIPasteboard.general.string = visibleAnswer(turn.text) } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
