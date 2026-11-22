import SwiftUI
import StudioCore

enum StudioSection: String, CaseIterable, Identifiable {
    case vision = "Photos"
    case live = "Live"
    case chat = "Chat"
    case ask = "Ask an image"
    case speech = "Speech to text"
    case assistant = "Assistant"
    case slides = "Raise hand to flip"
    case handCounter = "Hand-raise counter"
    case airInstrument = "Air instrument"
    case yoga = "Yoga coach"
    case squatAlarm = "Squat alarm"
    case reps = "Rep counter"
    case classroom = "Classroom"
    case headCount = "Head count"
    case traffic = "Traffic count"
    case missing = "Missing check"
    case plateGate = "Plate gate"
    case edgeCloud = "Edge vs cloud"
    case faceCheckIn = "Face check-in"
    case privacy = "Privacy camera"
    case handSigns = "Hand signs"
    case fruitNinja = "Fruit ninja"
    case eggs = "Catch the eggs"
    case airBand = "Air band"
    case photoRestore = "Photo restore"
    case outfit = "Outfit advisor"
    case fridge = "Fridge chef"
    case calories = "Calories"
    case faceReport = "Face style report"
    case offlineCode = "Offline code"
    case meetingNotes = "Meeting notes"
    case device = "Device and models"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .vision: return "photo"
        case .live: return "video"
        case .chat: return "bubble.left.and.bubble.right"
        case .ask: return "photo.badge.magnifyingglass"
        case .speech: return "waveform"
        case .assistant: return "waveform.and.mic"
        case .slides: return "hand.point.right"
        case .handCounter: return "hand.raised"
        case .airInstrument: return "music.note"
        case .yoga: return "figure.yoga"
        case .squatAlarm: return "alarm"
        case .reps: return "figure.strengthtraining.functional"
        case .classroom: return "person.3"
        case .headCount: return "person.2.crop.square.stack"
        case .traffic: return "car.2"
        case .missing: return "exclamationmark.triangle"
        case .plateGate: return "parkingsign.circle"
        case .edgeCloud: return "cloud.bolt"
        case .faceCheckIn: return "person.crop.square.badge.checkmark"
        case .privacy: return "eye.slash"
        case .handSigns: return "hand.thumbsup"
        case .fruitNinja: return "scissors"
        case .eggs: return "oval.portrait"
        case .airBand: return "guitars"
        case .photoRestore: return "wand.and.stars"
        case .outfit: return "tshirt"
        case .fridge: return "refrigerator"
        case .calories: return "fork.knife"
        case .faceReport: return "face.smiling"
        case .offlineCode: return "chevron.left.forwardslash.chevron.right"
        case .meetingNotes: return "list.bullet.clipboard"
        case .device: return "cpu"
        }
    }

    static let groups: [(title: String, items: [StudioSection])] = [
        ("Vision", [.vision, .live]),
        ("Language", [.chat, .ask, .speech]),
        ("Examples", [.assistant]),
        ("Body and pose", [.slides, .handCounter, .airInstrument, .yoga, .squatAlarm, .reps, .classroom]),
        ("Objects", [.headCount, .traffic, .missing, .plateGate, .edgeCloud]),
        ("Faces", [.faceCheckIn, .privacy]),
        ("Hands", [.handSigns, .fruitNinja, .eggs, .airBand]),
        ("Pictures", [.photoRestore]),
        ("Ask the models", [.outfit, .fridge, .calories, .faceReport, .offlineCode, .meetingNotes]),
        ("System", [.device]),
    ]
}

/// Artelico's mark: an "a." on a rounded tile (placeholder until there is a real logo).
struct LogoMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.08, blue: 0.30), Color(red: 0.42, green: 0.16, blue: 0.48)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.16)
                .stroke(Color(red: 0.98, green: 0.72, blue: 0.55).opacity(0.7), lineWidth: size * 0.04)
                .padding(size * 0.17)
            HStack(alignment: .firstTextBaseline, spacing: size * 0.01) {
                Text("a").foregroundStyle(.white)
                Text(".").foregroundStyle(Color(red: 0.98, green: 0.62, blue: 0.42))
            }
            .font(.system(size: size * 0.46, weight: .bold))
        }
        .frame(width: size, height: size)
    }
}

struct ContentView: View {
    @StateObject private var studio = StudioModel()
    @State private var section: StudioSection? = ContentView.initialSection
    @Environment(\.scenePhase) private var scenePhase

    /// `-section <name>` and `-stream` choose the first screen (used when testing from the Mac).
    private static var initialSection: StudioSection {
        let arguments = CommandLine.arguments
        if arguments.contains("-stream") { return .live }
        if let index = arguments.firstIndex(of: "-section"), index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "live": return .live
            case "chat": return .chat
            case "ask": return .ask
            case "speech": return .speech
            case "device": return .device
            case "assistant": return .assistant
            case "slides": return .slides
            case "handcount": return .handCounter
            case "air": return .airInstrument
            case "yoga": return .yoga
            case "squat": return .squatAlarm
            case "reps": return .reps
            case "classroom": return .classroom
            case "headcount": return .headCount
            case "traffic": return .traffic
            case "missing": return .missing
            case "plates": return .plateGate
            case "edgecloud": return .edgeCloud
            case "checkin": return .faceCheckIn
            case "privacy": return .privacy
            case "signs": return .handSigns
            case "fruit": return .fruitNinja
            case "eggs": return .eggs
            case "band": return .airBand
            case "restore": return .photoRestore
            case "outfit": return .outfit
            case "fridge": return .fridge
            case "calories": return .calories
            case "facereport": return .faceReport
            case "code": return .offlineCode
            case "notes": return .meetingNotes
            default: return .vision
            }
        }
        return .vision
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(StudioSection.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            Label(item.rawValue, systemImage: item.icon).tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Artelico")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { LogoMark(size: 30) }
            }
            .safeAreaInset(edge: .bottom) {
                StatusBar().padding(12)
            }
        } detail: {
            NavigationStack {
                switch section ?? .vision {
                case .vision: VisionView()
                case .live: LiveView()
                case .speech: SpeechView()
                case .assistant: AssistantView()
                case .slides: SlidesExampleView()
                case .handCounter: HandCounterExampleView()
                case .airInstrument: AirInstrumentExampleView()
                case .yoga: YogaExampleView()
                case .squatAlarm: SquatAlarmExampleView()
                case .reps: RepCounterExampleView()
                case .classroom: ClassroomExampleView()
                case .headCount: HeadCountExampleView()
                case .traffic: TrafficCountExampleView()
                case .missing: MissingCheckExampleView()
                case .plateGate: PlateGateExampleView()
                case .privacy: PrivacyCameraExampleView()
                case .edgeCloud: EdgeCloudExampleView()
                case .faceCheckIn: FaceCheckInExampleView()
                case .handSigns: GestureCaptionExampleView()
                case .fruitNinja: FruitNinjaExampleView()
                case .eggs: EggCatchExampleView()
                case .airBand: AirBandExampleView()
                case .photoRestore: PhotoRestoreExampleView()
                case .outfit: OutfitAdvisorExampleView()
                case .fridge: FridgeChefExampleView()
                case .calories: CaloriesExampleView()
                case .faceReport: FaceReportExampleView()
                case .offlineCode: OfflineCodeExampleView()
                case .meetingNotes: MeetingNotesExampleView()
                case .chat: ChatView()
                case .ask: AskImageView()
                case .device: DeviceView()
                }
            }
        }
        .environmentObject(studio)
        .task {
            FileDownloader.removeLeftovers()   // pieces of downloads interrupted in an earlier run
            Task { await studio.refreshModelMaps() }   // maps made or fixed since these models were downloaded
            if CommandLine.arguments.contains("-api") { studio.startAPI() }
            NativeBench.runIfRequested()
            #if DEBUG
            await studio.redownloadTestIfRequested()
            #endif
        }
    }
}

/// Where models run, at the bottom of the sidebar.
struct StatusBar: View {
    @EnvironmentObject private var studio: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Color.green).frame(width: 9, height: 9)
                Text("On this \(StudioModel.deviceKind)").font(.footnote.weight(.semibold))
                Spacer()
                Text(studio.computeUnits.title).font(.caption).foregroundStyle(.secondary)
            }
            if let name = studio.loadedModel {
                Label(name, systemImage: "shippingbox").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if studio.status != "Ready" {
                Text(studio.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if studio.apiRunning {
                Label("REST API on", systemImage: "network").font(.caption).foregroundStyle(.green)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Task and model pickers shared by the photo and live views.
struct TaskModelPicker: View {
    @Binding var task: VisionTask
    @Binding var modelName: String
    /// Live views leave out tasks that need two pictures at once.
    var live = false

    private var tasks: [VisionTask] {
        VisionTask.allCases.filter { !live || $0 != .stereoDepth }
    }

    @EnvironmentObject private var studio: StudioModel

    /// Models for the task, the ones on this device first.
    var models: [ModelInfo] {
        let all = ModelCatalog.models(for: task.rawValue).filter { VisionPipeline.supports(task, model: $0) }
        return all.filter { studio.installed.contains($0.name) } + all.filter { !studio.installed.contains($0.name) }
    }

    var body: some View {
        HStack {
            Picker("Task", selection: $task) {
                ForEach(tasks) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Picker("Model", selection: $modelName) {
                ForEach(models) { model in
                    Text(studio.installed.contains(model.name) ? model.name : "\(model.name) (downloads when used)").tag(model.name)
                }
            }
            .fixedSize()
        }
        .pickerStyle(.menu)
        .onChange(of: task) { _, _ in pickAvailable() }
        .onAppear { pickAvailable() }
    }

    /// Keeps the choice when it fits the task and is on this device; otherwise takes the first model that is.
    private func pickAvailable() {
        let fits = models.contains { $0.name == modelName }
        if !fits || !studio.installed.contains(modelName), let first = models.first {
            modelName = first.name
        }
    }
}

/// Extra settings that only some tasks have.
struct TaskOptions: View {
    let task: VisionTask
    @Binding var tiles: Int
    @Binding var promptText: String

    var body: some View {
        switch task {
        case .detection:
            Picker("Tiles", selection: $tiles) {
                Text("Whole picture").tag(1)
                Text("2 × 2 tiles").tag(2)
                Text("3 × 3 tiles").tag(3)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Also run the detector on overlapping tiles to find small objects")
        case .tagging:
            TextField("Things to look for, separated by commas; start with - for “not this”", text: $promptText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260, maxWidth: 520)
        case .findAnything, .describeObjects:
            PromptOptions(task: task, promptText: $promptText)   // Components.swift
        default:
            EmptyView()
        }
    }
}
