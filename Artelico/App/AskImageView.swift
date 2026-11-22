import CoreGraphics
import SwiftUI
import StudioCore

struct AskExchange: Identifiable {
    let id = UUID()
    let question: String
    var answer: String
    var seconds: Double?
    var tokens = 0
}

/// Ask questions about a picture with a vision language model running on this device (llama.cpp with
/// the model's image encoder). Follow-up questions see the picture and the earlier answers.
struct AskImageView: View {
    @EnvironmentObject private var studio: StudioModel
    @Environment(\.horizontalSizeClass) private var widthClass
    @AppStorage("ask.maxTokens") private var maxTokens = 256
    @AppStorage("ask.model") private var modelID = GGUFModel.catalog.first { $0.purpose == .vision }!.id
    @State private var engine: LlamaEngine?
    @State private var image: CGImage?
    @State private var imageName: String?
    @State private var exchanges: [AskExchange] = []
    @State private var question = ""
    @State private var note = ""
    @State private var generating: Task<Void, Never>?
    @FocusState private var typing: Bool

    private var visionModels: [GGUFModel] { studio.languageModels.filter { $0.purpose == .vision } }
    private var model: GGUFModel? { visionModels.first { $0.id == modelID } }

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
            modelRow
            if widthClass == .compact {
                VStack(spacing: 10) {
                    picture.frame(maxHeight: 260)
                    conversation.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal).padding(.bottom, 10)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    picture.frame(maxWidth: .infinity, maxHeight: .infinity)
                    conversation.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal).padding(.bottom, 10)
            }

            PictureChooser(key: "ask", selected: imageName) { picked, name in
                generating?.cancel()
                image = picked
                imageName = name
                exchanges = []
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
                Button("Clear") { exchanges = []; note = "" }.disabled(exchanges.isEmpty || generating != nil)
            }
        }
        .onAppear {
            if model == nil, let first = visionModels.first { modelID = first.id }
            if image == nil, let sample = SamplePicture.ordered(for: "ask").first {
                image = sample.load()
                imageName = sample.file
            }
            // `-ask "<question>" [-askmodel <file>]` asks about the first sample at launch (testing from the Mac).
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "-askmodel"), index + 1 < arguments.count { modelID = arguments[index + 1] }
            if let index = arguments.firstIndex(of: "-ask"), index + 1 < arguments.count, exchanges.isEmpty { ask(arguments[index + 1]) }
        }
    }

    private var modelRow: some View {
        HStack(spacing: 10) {
            Picker("Model", selection: $modelID) {
                ForEach(visionModels) { item in
                    Text(studio.isDownloaded(item) ? item.title : "\(item.title) (\(String(format: "%.1f", Double(item.totalMegabytes) / 1000)) GB download)").tag(item.id)
                }
            }
            .pickerStyle(.menu).fixedSize()
            .disabled(generating != nil)
            if let progress = studio.llmDownloads[modelID] {
                ProgressView(value: progress).frame(width: 120)
                Text(studio.llmDownloadInfo[modelID] ?? "\(Int(progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private var picture: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground))
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding(6)
            } else {
                ContentUnavailableView("No picture", systemImage: "photo", description: Text("Pick one from the strip below."))
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
                                Label(model?.title ?? "Vision model", systemImage: "eye").font(.headline)
                                Text("Ask anything about the picture. The model runs on this \(StudioModel.deviceKind); nothing leaves it.")
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
                                    FormattedText(text: visibleAnswer(exchange.answer))
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
                    Button { generating?.cancel(); if let engine { Task { await engine.cancel() } } } label: { Image(systemName: "stop.fill") }.buttonStyle(.bordered)
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
        guard let image, let chosen = model, !asked.isEmpty, generating == nil else { return }
        question = ""
        note = ""
        let earlier = exchanges
        exchanges.append(AskExchange(question: asked, answer: ""))
        let index = exchanges.count - 1
        generating = Task {
            defer { generating = nil; engine = nil; saveForTesting() }
            do {
                // Keep the screen on while downloading, loading and answering (a lock would suspend the app).
                UIApplication.shared.isIdleTimerDisabled = true
                defer { UIApplication.shared.isIdleTimerDisabled = false }
                let llm = try await studio.languageModel(chosen, forPictures: true)
                engine = llm
                // The picture goes with the first question; follow-ups repeat the earlier exchanges.
                var messages: [LlamaEngine.Message] = []
                for (number, exchange) in (earlier + [AskExchange(question: asked, answer: "")]).enumerated() {
                    let content = number == 0 ? LlamaEngine.pictureMarker + "\n" + exchange.question : exchange.question
                    messages.append(.init(role: "user", content: content))
                    if !exchange.answer.isEmpty { messages.append(.init(role: "assistant", content: visibleAnswer(exchange.answer))) }
                }
                guard let picture = Self.rgb(image, longestSide: 1024) else { throw StudioError.invalidInput("This picture cannot be read.") }
                var parameters = LlamaEngine.Parameters()
                parameters.maxTokens = maxTokens
                parameters.temperature = 0.2
                let (pieces, sink) = AsyncStream<String>.makeStream()
                let work = Task.detached {
                    defer { sink.finish() }
                    return try await llm.generate(messages, picture: picture, parameters: parameters) { sink.yield($0) }
                }
                for await piece in pieces { exchanges[index].answer += piece }
                let stats = try await work.value
                exchanges[index].seconds = stats.generationSeconds
                exchanges[index].tokens = stats.generatedTokens
                lastStats = String(format: "picture + prompt %d tokens in %.2f s; answer %d tokens in %.2f s = %.1f tokens/s",
                                   stats.promptTokens, stats.promptSeconds, stats.generatedTokens, stats.generationSeconds, stats.tokensPerSecond)
            } catch is CancellationError {
            } catch {
                studio.fail(error)
                note = "\(error)"
            }
        }
    }

    @State private var lastStats = ""

    /// Writes the last answer to Documents/ask-result.txt so it can be read from the Mac without a screenshot.
    private func saveForTesting() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let lines = ["model: \(model?.title ?? "?") picture: \(imageName ?? "?")", lastStats, note.isEmpty ? "" : "error: \(note)",
                     "Q: \(exchanges.last?.question ?? "")", visibleAnswer(exchanges.last?.answer ?? "")].filter { !$0.isEmpty }
        try? lines.joined(separator: "\n").write(to: documents.appendingPathComponent("ask-result.txt"), atomically: true, encoding: .utf8)
    }

    /// The picture as RGB bytes, scaled down so the longest side is at most `longestSide` pixels.
    static func rgb(_ image: CGImage, longestSide: Int) -> LlamaEngine.Picture? {
        let scale = min(1, Double(longestSide) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[3 * i] = rgba[4 * i]; rgb[3 * i + 1] = rgba[4 * i + 1]; rgb[3 * i + 2] = rgba[4 * i + 2]
        }
        return LlamaEngine.Picture(rgb: rgb, width: width, height: height)
    }
}
