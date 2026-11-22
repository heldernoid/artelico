import SwiftUI
import StudioCore

/// "Rep counter": counts squats, push-ups, pull-ups, sit-ups, jumping jacks or lunges for everyone in the
/// picture at once (hailo-apps' `--aigym` mode). Each person gets a tag with their count over their head.
/// There is no "auto" exercise: from one camera angle a squat and a lunge, or a push-up and a pull-up,
/// bend the same joints the same way, so guessing would count the wrong thing.
struct RepCounterExampleView: View {
    @EnvironmentObject private var studio: StudioModel
    @StateObject private var runner = PoseRunner()
    @AppStorage("reps.exercise") private var exercise = Exercise.squats
    @AppStorage("reps.sound") private var sound = true
    @State private var counter = RepCounter()
    /// Copies of the counter's state for the views (the counter is a class).
    @State private var people: [Int: RepTracker] = [:]
    @State private var total = 0
    /// The newest frame's time, for the tags' short "pop" after a rep.
    @State private var lastFrameTime = 0.0

    var body: some View {
        VStack(spacing: 10) {
            PoseControls(runner: runner, samples: [SampleMedia.squats, SampleMedia.office], start: start)
            ExampleLayout(panelWidth: 300) {
                PoseStage(runner: runner, tint: tint, placeholder: "Tap Start and step back so your whole body is in the picture.") { size in
                    tags(size)
                }
            } panel: {
                ExamplePanel { panel }
            }
        }
        .navigationTitle("Rep counter")
        .onDisappear { runner.stop() }
        .modifier(AutoStart(start: start))
    }

    /// Green at rest, orange in the work position, grey before the first position is seen.
    private func tint(_ index: Int, _ pose: Pose) -> Color {
        switch pose.trackID.flatMap({ people[$0]?.phase }) {
        case .work: return .orange
        case .rest: return .green
        case nil: return .gray
        }
    }

    /// A count tag above each person's head (it grows for a moment after a rep), and their form hint under it.
    @ViewBuilder private func tags(_ size: CGSize) -> some View {
        ForEach(runner.poses.filter { $0.trackID.flatMap { people[$0] } != nil }, id: \.trackID) { pose in
            let person = people[pose.trackID!]!
            let pop = 1 + 0.35 * max(0, 1 - (lastFrameTime - person.lastCount) / 0.4)
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(pose.trackID!)").font(.caption.bold()).opacity(0.8)   // the number in the panel's list
                    Text("\(person.count)").font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 2)
                .background(person.phase == .work ? Color.orange : Color.green, in: Capsule())
                .scaleEffect(pop)
                if !person.hint.isEmpty {
                    Text(person.hint).font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: Capsule())
                        .fixedSize()
                }
            }
            .position(x: pose.boundingBox.midX * size.width, y: max(24, pose.boundingBox.minY * size.height - 22))
        }
    }

    @ViewBuilder private var panel: some View {
        Picker("Exercise", selection: $exercise) {
            ForEach(Exercise.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .onChange(of: exercise) { _, value in counter.exercise = value; refresh() }
        HStack(alignment: .firstTextBaseline) {
            Text("\(total)").font(.system(size: 64, weight: .heavy, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text(total == 1 ? "rep in all" : "reps in all").font(.title3).foregroundStyle(.secondary)
        }
        Button("Reset", systemImage: "arrow.counterclockwise") { counter.reset(); refresh() }
        if !people.isEmpty {
            Divider()
            ForEach(people.keys.sorted(), id: \.self) { id in
                let person = people[id]!
                HStack {
                    Text("Person \(id)")
                    Spacer()
                    if let angle = person.angle { Text("\(Int(angle))°").foregroundStyle(.secondary).monospacedDigit() }
                    Text("\(person.count)").font(.headline.monospacedDigit()).frame(minWidth: 30, alignment: .trailing)
                }
            }
        }
        Divider()
        Toggle("Sound per rep", isOn: $sound)
        Text("Watches the \(exercise.measures): a rep is going past \(Int(exercise.work))° and coming back past \(Int(exercise.rest))°. Half reps don't count and get a hint. Keep the joints in view; side-on works best for push-ups, pull-ups and sit-ups.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func refresh() {
        people = counter.people
        total = counter.total
    }

    private func start() {
        counter = RepCounter(exercise: exercise)
        refresh()
        runner.start(studio: studio) { frame in
            lastFrameTime = frame.time
            let counted = counter.update(frame.bodies(), now: frame.time)
            if sound {
                // Each rep a note, climbing the scale with that person's count.
                for id in counted { ToneSynth.shared.play(ToneSynth.scale[((counter.people[id]?.count ?? 1) - 1) % ToneSynth.scale.count], seconds: 0.18, bright: true, volume: 0.4) }
            }
            withAnimation(.snappy) { refresh() }
            #if DEBUG
            if CommandLine.arguments.contains("-replog"), !counted.isEmpty {
                print(String(format: "reps t=%.2f", frame.time), counted.map { "#\($0)=\(counter.people[$0]!.count)" }.joined(separator: " "), "total", counter.total)
                fflush(stdout)
            }
            #endif
        }
    }
}
