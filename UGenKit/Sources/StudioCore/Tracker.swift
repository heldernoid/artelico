import CoreGraphics
import Foundation

/// A detection with an identity that stays the same from frame to frame.
public struct TrackedDetection: Sendable {
    public let detection: Detection
    public let trackID: Int

    public init(detection: Detection, trackID: Int) {
        self.detection = detection
        self.trackID = trackID
    }
}

/// Follows objects across frames and gives each one a stable number.
///
/// The method is ByteTrack-style association by box overlap (IoU):
///
/// 1. Every track's box is moved forward one frame with a constant-velocity model.
/// 2. Stage 1: confident detections are matched to confirmed tracks, including lost ones.
/// 3. Stage 2: tracks still unmatched that were seen on the previous frame are matched to the
///    low-confidence detections, so an object whose score dips (blur, partial occlusion) keeps its number.
/// 4. Confident detections still unmatched are matched to tentative tracks, then start new tentative tracks.
/// 5. Confirmed tracks without a match are kept as "lost" for `maxLostFrames` frames and can be re-found.
///
/// Each stage solves the assignment optimally (Hungarian algorithm), maximising the total IoU of the pairs.
///
/// A track gets its number when it is first reported, so reported numbers are 1, 2, 3, ... without gaps
/// and are never reused until `reset()`. As in ByteTrack, tracks started on the very first frame are
/// reported immediately, so a single still image also gets numbers.
public struct ObjectTracker: Sendable {
    /// Detections at or above this confidence can match in stage 1 and can start new tracks.
    public let highConfidenceThreshold: Float
    /// Detections at or above this (and below the high threshold) can only continue an existing track.
    /// Anything below is ignored.
    public let lowConfidenceThreshold: Float
    /// Smallest overlap (intersection over union) between a predicted track box and a detection to pair them.
    public let matchIoUThreshold: Double
    /// How many consecutive frames a confirmed track may go unmatched before it is dropped.
    public let maxLostFrames: Int
    /// How many consecutive frames a new object must be matched before it is reported (1 = immediately).
    public let minimumHits: Int
    /// When true, a track only matches detections with the same `classIndex`.
    public let matchSameClassOnly: Bool

    private var tracks: [Track] = []
    private var nextTrackID = 1
    private var frameCount = 0
    /// Whether `track(_:)` steadies numbered boxes and body points (see TrackSmoother). Off gives the raw
    /// per-frame positions.
    public var steadies = true
    private var smoother = TrackSmoother()

    public init() {
        self.init(highConfidenceThreshold: 0.5)
    }

    public init(
        highConfidenceThreshold: Float = 0.5,
        lowConfidenceThreshold: Float = 0.1,
        matchIoUThreshold: Double = 0.2,
        maxLostFrames: Int = 30,
        minimumHits: Int = 2,
        matchSameClassOnly: Bool = true
    ) {
        self.highConfidenceThreshold = highConfidenceThreshold
        self.lowConfidenceThreshold = min(lowConfidenceThreshold, highConfidenceThreshold)
        self.matchIoUThreshold = max(matchIoUThreshold, .leastNonzeroMagnitude)
        self.maxLostFrames = max(maxLostFrames, 0)
        self.minimumHits = max(minimumHits, 1)
        self.matchSameClassOnly = matchSameClassOnly
    }

    /// Forgets every track. Numbers start again at 1.
    public mutating func reset() {
        smoother.reset()
        tracks.removeAll()
        nextTrackID = 1
        frameCount = 0
    }

    /// Call once per frame with that frame's detections.
    ///
    /// Returns the detections that belong to confirmed tracks, in their input order. Detections that are
    /// too weak, unmatched low-confidence ones and objects not yet seen `minimumHits` times are left out.
    public mutating func update(_ detections: [Detection]) -> [TrackedDetection] {
        frameCount += 1

        // Split the detections by confidence. Boxes that are empty or not finite cannot be tracked.
        let boxes = detections.map { TrackBox($0.boundingBox) }
        var highDetections: [Int] = []
        var lowDetections: [Int] = []
        for (index, detection) in detections.enumerated() where boxes[index].isUsable {
            if detection.confidence >= highConfidenceThreshold {
                highDetections.append(index)
            } else if detection.confidence >= lowConfidenceThreshold {
                lowDetections.append(index)
            }
        }

        for index in tracks.indices {
            tracks[index].predict()
        }

        let confirmed = tracks.indices.filter { tracks[$0].id != nil }
        let tentative = tracks.indices.filter { tracks[$0].id == nil }
        /// For each detection, the index in `tracks` of the track it was matched to.
        var trackForDetection = [Int?](repeating: nil, count: detections.count)

        // Stage 1: confident detections against all confirmed tracks (active and lost).
        let first = associate(confirmed, highDetections, detections: detections, boxes: boxes)
        for (track, detection) in first.pairs { trackForDetection[detection] = track }

        // Stage 2: low-confidence detections against tracks that were visible on the previous frame.
        let stillActive = first.unmatchedTracks.filter { tracks[$0].framesSinceMatch == 0 }
        let second = associate(stillActive, lowDetections, detections: detections, boxes: boxes)
        for (track, detection) in second.pairs { trackForDetection[detection] = track }

        // Tentative tracks may only be continued by confident detections.
        let third = associate(tentative, first.unmatchedDetections, detections: detections, boxes: boxes)
        for (track, detection) in third.pairs { trackForDetection[detection] = track }

        // Apply the matches in detection order, so that numbers are handed out deterministically.
        var matchedTracks = Set<Int>()
        var newTracks: [Track] = []
        var results: [TrackedDetection] = []
        let unmatchedHigh = Set(third.unmatchedDetections)
        for (detectionIndex, detection) in detections.enumerated() {
            var track: Track
            if let trackIndex = trackForDetection[detectionIndex] {
                matchedTracks.insert(trackIndex)
                tracks[trackIndex].correct(with: boxes[detectionIndex])
                track = tracks[trackIndex]
            } else if unmatchedHigh.contains(detectionIndex) {
                track = Track(classIndex: detection.classIndex, box: boxes[detectionIndex])
            } else {
                continue
            }

            if track.id == nil, track.hits >= minimumHits || frameCount == 1 {
                track.id = nextTrackID
                nextTrackID += 1
            }
            if let id = track.id {
                results.append(TrackedDetection(detection: detection, trackID: id))
            }

            if let trackIndex = trackForDetection[detectionIndex] {
                tracks[trackIndex] = track
            } else {
                newTracks.append(track)
            }
        }

        // Unmatched confirmed tracks become (or stay) lost until the window runs out;
        // unmatched tentative tracks are dropped at once.
        var kept: [Track] = []
        for (index, var track) in tracks.enumerated() {
            if !matchedTracks.contains(index) {
                guard track.id != nil, track.framesSinceMatch < maxLostFrames else { continue }
                track.framesSinceMatch += 1
            }
            kept.append(track)
        }
        tracks = kept + newTracks
        return results
    }

    /// Pairs tracks with detections so that the total IoU of the accepted pairs is as large as possible.
    /// `trackIndices` index into `tracks`, `detectionIndices` into `detections` and `boxes`.
    private func associate(
        _ trackIndices: [Int],
        _ detectionIndices: [Int],
        detections: [Detection],
        boxes: [TrackBox]
    ) -> (pairs: [(track: Int, detection: Int)], unmatchedTracks: [Int], unmatchedDetections: [Int]) {
        guard !trackIndices.isEmpty, !detectionIndices.isEmpty else {
            return ([], trackIndices, detectionIndices)
        }

        // Overlap of every allowed pair; 0 marks a pair that must not be matched.
        let overlap: [[Double]] = trackIndices.map { trackIndex in
            let track = tracks[trackIndex]
            return detectionIndices.map { detectionIndex in
                if matchSameClassOnly, detections[detectionIndex].classIndex != track.classIndex { return 0 }
                let iou = track.box.iou(with: boxes[detectionIndex])
                return iou >= matchIoUThreshold ? iou : 0
            }
        }
        // A forbidden pair costs 1, the same as leaving both unmatched, so minimising the total cost
        // maximises the total overlap of the allowed pairs.
        let assignment = Assignment.solve(cost: overlap.map { row in row.map { 1 - $0 } })

        var pairs: [(track: Int, detection: Int)] = []
        var unmatchedTracks: [Int] = []
        var detectionTaken = [Bool](repeating: false, count: detectionIndices.count)
        for (row, column) in assignment.enumerated() {
            if let column, overlap[row][column] > 0 {
                pairs.append((trackIndices[row], detectionIndices[column]))
                detectionTaken[column] = true
            } else {
                unmatchedTracks.append(trackIndices[row])
            }
        }
        let unmatchedDetections = detectionIndices.indices.filter { !detectionTaken[$0] }.map { detectionIndices[$0] }
        return (pairs, unmatchedTracks, unmatchedDetections)
    }
}

// MARK: - Track state

/// A box as centre and size, in normalized image coordinates.
private struct TrackBox: Sendable {
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        let rect = rect.standardized
        centerX = Double(rect.midX)
        centerY = Double(rect.midY)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    var isUsable: Bool {
        centerX.isFinite && centerY.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }

    func iou(with other: TrackBox) -> Double {
        let overlapWidth = min(centerX + width / 2, other.centerX + other.width / 2)
            - max(centerX - width / 2, other.centerX - other.width / 2)
        let overlapHeight = min(centerY + height / 2, other.centerY + other.height / 2)
            - max(centerY - height / 2, other.centerY - other.height / 2)
        guard overlapWidth > 0, overlapHeight > 0 else { return 0 }
        let intersection = overlapWidth * overlapHeight
        let union = width * height + other.width * other.height - intersection
        return union > 0 ? intersection / union : 0
    }
}

/// One followed object: its predicted box and how fast the box moves and grows per frame.
private struct Track: Sendable {
    /// How strongly a new measurement corrects the velocity estimate (0...1).
    static let velocityGain = 0.3
    /// A lost track coasts on its last velocity, which fades by this factor every frame.
    static let lostVelocityDecay = 0.95
    static let minimumSize = 1e-4

    /// The reported number; nil while the track is tentative.
    var id: Int?
    let classIndex: Int
    var box: TrackBox
    /// Change per frame of centre x, centre y, width and height.
    var velocity = (x: 0.0, y: 0.0, width: 0.0, height: 0.0)
    /// Number of detections matched to this track so far.
    var hits = 1
    /// 0 when matched on the latest frame, otherwise the number of frames it has been lost.
    var framesSinceMatch = 0

    init(classIndex: Int, box: TrackBox) {
        self.classIndex = classIndex
        self.box = box
    }

    /// Moves the box forward by one frame.
    mutating func predict() {
        box.centerX += velocity.x
        box.centerY += velocity.y
        if framesSinceMatch == 0 {
            box.width = max(box.width + velocity.width, Self.minimumSize)
            box.height = max(box.height + velocity.height, Self.minimumSize)
        } else {
            // Unseen: keep the size and let the motion fade, so a wrong estimate cannot run away.
            velocity.x *= Self.lostVelocityDecay
            velocity.y *= Self.lostVelocityDecay
            velocity.width = 0
            velocity.height = 0
        }
    }

    /// Takes the matched detection's box as the new position and corrects the velocity by how far
    /// the prediction was off (an alpha-beta filter with alpha = 1).
    mutating func correct(with measured: TrackBox) {
        let framesElapsed = Double(framesSinceMatch + 1)
        // The second sighting gives the first velocity estimate; use it in full.
        let gain = (hits == 1 ? 1 : Self.velocityGain) / framesElapsed
        velocity.x += gain * (measured.centerX - box.centerX)
        velocity.y += gain * (measured.centerY - box.centerY)
        velocity.width += gain * (measured.width - box.width)
        velocity.height += gain * (measured.height - box.height)
        box = measured
        hits += 1
        framesSinceMatch = 0
    }
}

// MARK: - Assignment problem

/// The Hungarian algorithm (Kuhn-Munkres with potentials, O(n³)).
enum Assignment {
    /// Finds the cheapest way to give each row a different column (or each column a different row
    /// when there are more rows than columns).
    ///
    /// - Parameter cost: a rectangular matrix of finite costs, `cost[row][column]`.
    /// - Returns: for each row, its column, or nil for rows left over when rows outnumber columns.
    static func solve(cost: [[Double]]) -> [Int?] {
        let rowCount = cost.count
        let columnCount = cost.first?.count ?? 0
        guard rowCount > 0, columnCount > 0 else {
            return [Int?](repeating: nil, count: rowCount)
        }

        // The method below needs rows <= columns; otherwise solve the transposed problem.
        if rowCount > columnCount {
            let transposed = (0..<columnCount).map { column in (0..<rowCount).map { cost[$0][column] } }
            var result = [Int?](repeating: nil, count: rowCount)
            for (column, row) in solve(cost: transposed).enumerated() {
                if let row { result[row] = column }
            }
            return result
        }

        // Rows and columns are numbered from 1; index 0 is a placeholder column that holds the row
        // currently being inserted.
        var rowPotential = [Double](repeating: 0, count: rowCount + 1)
        var columnPotential = [Double](repeating: 0, count: columnCount + 1)
        /// The row assigned to each column (0 = free).
        var rowOfColumn = [Int](repeating: 0, count: columnCount + 1)
        /// The previous column on the cheapest alternating path to each column.
        var previousColumn = [Int](repeating: 0, count: columnCount + 1)

        for row in 1...rowCount {
            rowOfColumn[0] = row
            var currentColumn = 0
            var slack = [Double](repeating: .infinity, count: columnCount + 1)
            var visited = [Bool](repeating: false, count: columnCount + 1)

            // Grow the alternating tree until it reaches a free column.
            repeat {
                visited[currentColumn] = true
                let currentRow = rowOfColumn[currentColumn]
                var smallest = Double.infinity
                var nextColumn = 0
                for column in 1...columnCount where !visited[column] {
                    let reduced = cost[currentRow - 1][column - 1] - rowPotential[currentRow] - columnPotential[column]
                    if reduced < slack[column] {
                        slack[column] = reduced
                        previousColumn[column] = currentColumn
                    }
                    if slack[column] < smallest {
                        smallest = slack[column]
                        nextColumn = column
                    }
                }
                // Shift the potentials so that the cheapest edge out of the tree becomes tight.
                for column in 0...columnCount {
                    if visited[column] {
                        rowPotential[rowOfColumn[column]] += smallest
                        columnPotential[column] -= smallest
                    } else {
                        slack[column] -= smallest
                    }
                }
                currentColumn = nextColumn
            } while rowOfColumn[currentColumn] != 0

            // Flip the assignments along the path back to the placeholder column.
            repeat {
                let previous = previousColumn[currentColumn]
                rowOfColumn[currentColumn] = rowOfColumn[previous]
                currentColumn = previous
            } while currentColumn != 0
        }

        var result = [Int?](repeating: nil, count: rowCount)
        for column in 1...columnCount where rowOfColumn[column] != 0 {
            result[rowOfColumn[column] - 1] = column - 1
        }
        return result
    }
}

extension ObjectTracker {
    /// Adds a track number to every tracked item in a result: detections and masks get " #N" after their
    /// label, poses get `trackID`. Items the tracker has not confirmed yet are kept without a number.
    /// Numbered boxes and body points are steadied (`steadies`), timed by `time` (seconds; the clock by
    /// default). Masks keep their boxes as found, so they stay aligned. Other kinds of result are returned unchanged.
    public mutating func track(_ result: VisionResult, time: Double = ProcessInfo.processInfo.systemUptime) -> VisionResult {
        defer { smoother.forget(notSeenSince: time - 2) }
        func numbers(for detections: [Detection]) -> [Int?] {
            let tracked = update(detections)
            var ids = [Int?](repeating: nil, count: detections.count)
            var next = 0
            // `update` returns confirmed items in input order, so walk both lists together.
            for item in tracked {
                while next < detections.count, detections[next] != item.detection { next += 1 }
                guard next < detections.count else { break }
                ids[next] = item.trackID
                next += 1
            }
            return ids
        }
        func numbered(_ detection: Detection, _ id: Int?, steady: Bool = true) -> Detection {
            guard let id else { return detection }
            let box = steadies && steady ? smoother.box(detection.boundingBox, id: id, time: time) : detection.boundingBox
            return Detection(label: "\(detection.label) #\(id)", classIndex: detection.classIndex,
                             confidence: detection.confidence, boundingBox: box)
        }
        switch result {
        case .detections(let found):
            let ids = numbers(for: found)
            return .detections(zip(found, ids).map { numbered($0, $1) })
        case .instances(let found):
            let ids = numbers(for: found.map(\.detection))
            return .instances(zip(found, ids).map { instance, id in
                Instance(detection: numbered(instance.detection, id, steady: false), maskWidth: instance.maskWidth, maskHeight: instance.maskHeight, mask: instance.mask)
            })
        case .poses(let found):
            let ids = numbers(for: found.map { Detection(label: "person", classIndex: 0, confidence: $0.confidence, boundingBox: $0.boundingBox) })
            return .poses(zip(found, ids).map { pose, id in
                guard let id, steadies else {
                    var numberedPose = pose
                    numberedPose.trackID = id
                    return numberedPose
                }
                let box = smoother.box(pose.boundingBox, id: id, time: time)
                let points = smoother.points(pose.keypoints.map(\.position), id: id, time: time)
                let keypoints = zip(pose.keypoints, points).map { Pose.Keypoint(position: $1, confidence: $0.confidence) }
                return Pose(confidence: pose.confidence, boundingBox: box, keypoints: keypoints, trackID: id)
            })
        default:
            return result
        }
    }
}
