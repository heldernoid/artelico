import SwiftUI
import UGenKit

struct AskExchange: Identifiable {
    let id = UUID()
    let question: String
    var answer: String
    var seconds: Double?
    var tokens = 0
}

/// Ask questions about a picture. Follow-up questions about the same picture keep their context.
struct AskImageView: View {
    @EnvironmentObject private var studio: StudioModel
    @AppStorage("ask.maxTokens") private var maxTokens = 256
    @State private var image: CGImage?
    @State private var imageName: String?
    @State private var exchanges: [AskExchange] = []
    @State private var question = ""
    @State private var note = ""
    @State private var generating: Task<Void, Never>?
    @State private var imageSent = false
    @FocusState private var typing: Bool

    private let ideas: [(title: String, prompt: String)] = [
        ("Describe", "Describe this picture in detail."),
        ("What is it?", "What is in this picture?"),
        ("Read text", "What text can you read in this picture?"),
        ("Count", "How many people or objects can you see, and what are they?"),
        ("Calories", "List the food items you see and estimate the calories and protein of each."),
        ("Recipe ideas", "Suggest three dishes I could cook with the ingredients you see."),
        ("Outfit advice", "Comment on this outfit and suggest one improvement."),
        ("Safety check", "Is there anything unsafe or unusual in this scene?"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground))
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFit().padding(6)
                    } else {
                        ContentUnavailableView("No picture", systemImage: "photo", description: Text("Pick one from the strip below."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                conversation.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal).padding(.top, 10).padding(.bottom, 10)

            PictureChooser(key: "ask", selected: imageName) { picked, name in
                generating?.cancel()
                image = picked
                imageName = name
                exchanges = []
                imageSent = false
                note = ""
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Ask an image")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Stepper("Up to \(maxTokens) tokens per answer", value: $maxTokens, in: 64...1024, step: 64)
                } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                Button("Clear") { exchanges = []; imageSent = false; note = "" }.disabled(exchanges.isEmpty || generating != nil)
            }
        }
        .onAppear {
            if image == nil, let sample = SamplePicture.ordered(for: "ask").first {
                image = sample.load()
                imageName = sample.file
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if exchanges.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(StudioModel.visionChatModelName, systemImage: "eye").font(.headline)
                                Text("Ask anything about the picture on the left. The model runs on the stick; nothing leaves the \(StudioModel.deviceKind).")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(exchanges) { exchange in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(exchange.question).font(.callout.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                if exchange.answer.isEmpty {
                                    ProgressView()
                                } else {
                                    FormattedText(text: exchange.answer)
                                }
                                if let seconds = exchange.seconds {
                                    HStack {
                                        Chip(text: String(format: "%.1f s", seconds), systemImage: "timer")
                                        Chip(text: String(format: "%.1f tokens/s", Double(exchange.tokens) / max(seconds, 0.01)), systemImage: "speedometer")
                                        Button { UIPasteboard.general.string = exchange.answer } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                                    }
                                }
                            }
                            .id(exchange.id)
                        }
                        if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.red) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: exchanges.last?.answer) { _, _ in
                    if let last = exchanges.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(ideas, id: \.title) { idea in
                        Button(idea.title) { ask(idea.prompt) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            .disabled(image == nil || generating != nil)
            HStack {
                TextField("Ask about this picture", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4).focused($typing)
                    .onSubmit { ask(question) }
                if generating != nil {
                    Button { generating?.cancel() } label: { Image(systemName: "stop.fill") }.buttonStyle(.bordered)
                } else {
                    Button { ask(question) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .disabled(image == nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func ask(_ text: String) {
        let asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let image, !asked.isEmpty, generating == nil else { return }
        question = ""
        note = ""
        exchanges.append(AskExchange(question: asked, answer: ""))
        let index = exchanges.count - 1
        generating = Task {
            defer { generating = nil }
            do {
                let wasLoaded = studio.visionChatModel != nil
                let model = try await studio.visionChat()
                if !wasLoaded { imageSent = false }
                var parameters = model.defaultParameters
                parameters.maxGeneratedTokens = UInt32(maxTokens)
                let clock = ContinuousClock()
                let start = clock.now
                let stream: AsyncThrowingStream<String, Error>
                if imageSent {
                    // A follow-up: the stick still has the picture and the earlier answers.
                    stream = model.generate(messages: [.user(asked)], frames: [], parameters: parameters)
                } else {
                    try await model.clearContext()
                    stream = model.generate(messages: [.user(asked, images: 1)], frames: [try model.prepareFrame(image)], parameters: parameters)
                    imageSent = true
                }
                for try await piece in stream {
                    exchanges[index].answer += piece
                    exchanges[index].tokens += 1
                }
                let elapsed = clock.now - start
                exchanges[index].seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            } catch is CancellationError {
            } catch {
                studio.fail(error)
                note = "\(error)"
                imageSent = false
            }
        }
    }
}
