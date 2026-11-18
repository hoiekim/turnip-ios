import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import XCTest
@testable import Turnip

/// Measures how well Clip List's shirt colour filter (`ClipFilter`) keeps one person's clips and
/// hides everyone else's on hand-labelled footage, beside the ways it could tell them apart instead.
///
/// Skipped unless the run names the evaluation directory, as `TrickDetectionEvaluationTests` does
/// (`TEST_RUNNER_TURNIP_EVAL_DIR`), and the person whose clips to keep (`TEST_RUNNER_TURNIP_EVAL_ME`,
/// a `person` in its `labels.json`). It reads only the videos with a trick labelled with that person,
/// and detects their clips following everyone, as the app does. A clip is that person's when it
/// overlaps one of their labelled tricks and, where the label says where they are (`at`), its crop
/// frames that point. Every other clip is someone else's, including a false positive of their own.
///
/// It prints `TURNIP_SHIRT` lines and writes `results/shirt-<label>.json` (`TEST_RUNNER_TURNIP_EVAL_LABEL`,
/// default `run`): numbers only. Under `shirt/<video>/` it draws each clip's two read moments with
/// the points read marked and the colour read in the corner, to show whether the reading lands on
/// the top; those are pictures of real people, and stay in the evaluation directory.
final class ShirtColorEvaluationTests: XCTestCase {
    func testTellMyClipsFromEveryoneElses() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TURNIP_EVAL_DIR"], let me = environment["TURNIP_EVAL_ME"] else {
            throw XCTSkip("Set TEST_RUNNER_TURNIP_EVAL_DIR and TEST_RUNNER_TURNIP_EVAL_ME to run this.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let manifest = try JSONDecoder().decode(
            EvaluationManifest.self, from: Data(contentsOf: directory.appendingPathComponent("labels.json")))
        var report = ShirtReport(label: environment["TURNIP_EVAL_LABEL"] ?? "run")

        for entry in manifest.clips {
            guard let myTricks = entry.tricks?.filter({ $0.person == me }), !myTricks.isEmpty else { continue }
            let readings = try await read(entry.video, myTricks: myTricks, in: directory)
            let lines = ShirtSummary.lines(for: readings, video: entry.video)
            lines.forEach { print("TURNIP_SHIRT " + $0) }
            report.videos.append(ShirtReport.Video(
                video: entry.video, lines: lines, clips: readings.map { ShirtReport.ClipRow($0, among: readings) }))
        }

        XCTAssertFalse(report.videos.isEmpty, "No video in labels.json has a trick labelled with that person.")
        let results = directory.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: results.appendingPathComponent("shirt-\(report.label).json"))
    }

    /// Detects one video's clips following everyone and reads each one every way being compared.
    private func read(
        _ video: String, myTricks: [LabelledTrick], in directory: URL
    ) async throws -> [ClipReading] {
        let asset = AVURLAsset(url: directory.appendingPathComponent(video))
        let selected = SelectedVideo(
            assetIdentifier: video, asset: asset, duration: try await asset.load(.duration).seconds)
        let detection = try await ProcessingPipeline().run(video: selected, people: .everyone) { _ in }.detection
        let drawings = directory.appendingPathComponent("shirt/\(video)", isDirectory: true)
        try FileManager.default.createDirectory(at: drawings, withIntermediateDirectories: true)
        var readings: [ClipReading] = []
        for (index, clip) in detection.clips.enumerated() {
            var reading = await ClipReading.read(
                clip, frames: detection.poseFrames(forPerson: clip.personID),
                isMine: Self.isMine(clip, myTricks: myTricks), asset: asset)
            reading.draw(to: drawings.appendingPathComponent(
                String(format: "%03d-%@-%.1fs.png", index, reading.isMine ? "mine" : "other", reading.start)))
            // Drawn: a long take's frames needn't all stay in memory.
            reading.moments = []
            readings.append(reading)
        }
        return readings
    }

    /// Whether `clip` is of one of the person's labelled tricks.
    static func isMine(_ clip: ProcessedClip, myTricks: [LabelledTrick]) -> Bool {
        myTricks.contains { trick in
            guard clip.window.startTime < trick.window.upperBound, clip.window.endTime > trick.window.lowerBound
            else { return false }
            guard let point = trick.position else { return true }
            let crop = clip.cropRect
            return crop.minX <= point.x && point.x <= crop.maxX && crop.minY <= point.y && point.y <= crop.maxY
        }
    }
}

// MARK: - Reading

/// One clip, read every way the evaluation compares.
private struct ClipReading {
    let start: TimeInterval
    let end: TimeInterval
    let personID: Int?
    let isMine: Bool
    /// The app's reading: `TorsoColorReader` over `TorsoSample.picks`, as Clip List reads a clip.
    let appColor: LabColor?
    /// The top over up to five moments instead of two.
    let fiveMomentColor: LabColor?
    /// The thighs at the app's two moments: shorts or trousers.
    let legColor: LabColor?
    /// Vision's feature print of the person's crop at each of the app's moments.
    let prints: [VNFeaturePrintObservation]
    /// What the drawing shows: the app's moments, decoded as the reader decodes them.
    var moments: [(sample: TorsoSample, image: CGImage)]
    /// How long the app's reading took.
    let appSeconds: TimeInterval

    static func read(
        _ clip: ProcessedClip, frames: [PoseFrameResult], isMine: Bool, asset: AVAsset
    ) async -> ClipReading {
        let picks = TorsoSample.picks(from: frames, in: clip.window)
        let started = Date()
        let appColor = await TorsoColorReader().color(of: picks, in: asset)
        let appSeconds = Date().timeIntervalSince(started)
        var moments: [(sample: TorsoSample, image: CGImage)] = []
        var legs: [LabColor] = []
        var prints: [VNFeaturePrintObservation] = []
        for sample in picks {
            guard let image = await frame(at: sample.timestamp, in: asset, maximumSize: TorsoColorReader.maximumSize)
            else { continue }
            moments.append((sample, image))
            let pose = frames.first { $0.timestamp == sample.timestamp }
            legs += pose.flatMap(legPoints).map { TorsoColorReader.colors(in: image, at: $0) } ?? []
            if let pose, let large = await frame(at: sample.timestamp, in: asset, maximumSize: printSize),
               let observation = featurePrint(of: large, person: pose) {
                prints.append(observation)
            }
        }
        var fiveMoments: [LabColor] = []
        for sample in TorsoSample.picks(from: frames, in: clip.window, count: 5, spacing: 0.3) {
            guard let image = await frame(at: sample.timestamp, in: asset, maximumSize: TorsoColorReader.maximumSize)
            else { continue }
            fiveMoments += TorsoColorReader.colors(in: image, at: sample.readingPoints)
        }
        return ClipReading(
            start: clip.window.startTime, end: clip.window.endTime, personID: clip.personID, isMine: isMine,
            appColor: appColor, fiveMomentColor: LabColor.median(of: fiveMoments), legColor: LabColor.median(of: legs),
            prints: prints, moments: moments, appSeconds: appSeconds)
    }

    /// Feature prints read the person's crop at a size closer to the source than the colour does.
    private static let printSize = CGSize(width: 960, height: 960)

    private static func frame(at time: TimeInterval, in asset: AVAsset, maximumSize: CGSize) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    /// Points down each thigh, hip to knee, kept short of both joints; `nil` unless both hips and
    /// both knees are located.
    private static func legPoints(in pose: PoseFrameResult) -> [CGPoint]? {
        func located(_ name: String) -> CGPoint? {
            pose.keypoints.first { $0.name == name && $0.confidence > PoseKeypoint.confidenceThreshold }
                .map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        }
        guard let leftHip = located("left_hip"), let rightHip = located("right_hip"),
              let leftKnee = located("left_knee"), let rightKnee = located("right_knee")
        else { return nil }
        let fractions: [CGFloat] = [0.2, 0.35, 0.5, 0.65]
        return [(leftHip, leftKnee), (rightHip, rightKnee)].flatMap { hip, knee in
            fractions.map { CGPoint(x: hip.x + (knee.x - hip.x) * $0, y: hip.y + (knee.y - hip.y) * $0) }
        }
    }

    /// Vision's feature print of the box around the person's located joints, padded a little; `nil`
    /// when too few joints are located or Vision fails.
    private static func featurePrint(of image: CGImage, person pose: PoseFrameResult) -> VNFeaturePrintObservation? {
        let joints = pose.keypoints.filter { $0.confidence > PoseKeypoint.confidenceThreshold }
        guard joints.count >= 6, let minX = joints.map(\.x).min(), let maxX = joints.map(\.x).max(),
              let minY = joints.map(\.y).min(), let maxY = joints.map(\.y).max()
        else { return nil }
        let padX = (maxX - minX) * 0.15
        let padY = (maxY - minY) * 0.1
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let box = CGRect(
            x: CGFloat(max(minX - padX, 0)) * width, y: CGFloat(max(minY - padY, 0)) * height,
            width: CGFloat(min(maxX + padX, 1) - max(minX - padX, 0)) * width,
            height: CGFloat(min(maxY + padY, 1) - max(minY - padY, 0)) * height
        ).integral
        guard box.width >= 8, box.height >= 8, let crop = image.cropping(to: box) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])) != nil else { return nil }
        return request.results?.first
    }

    /// The app's two moments side by side, each with its reading points marked, and the colour read
    /// in the bottom-left corner. Best effort: a drawing that fails is left out.
    func draw(to url: URL) {
        let width = moments.map(\.image.width).reduce(0, +)
        let height = moments.map(\.image.height).max() ?? 0
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        var originX = 0
        for moment in moments {
            let imageWidth = CGFloat(moment.image.width)
            let imageHeight = CGFloat(moment.image.height)
            context.draw(moment.image, in: CGRect(
                x: CGFloat(originX), y: CGFloat(height) - imageHeight, width: imageWidth, height: imageHeight))
            context.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 1))
            // A context's y runs up; the points' runs down from the top.
            for point in moment.sample.readingPoints {
                let center = CGPoint(
                    x: CGFloat(originX) + point.x * imageWidth, y: CGFloat(height) - point.y * imageHeight)
                context.fillEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
            }
            originX += moment.image.width
        }
        if let appColor {
            context.setFillColor(appColor.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

// MARK: - Comparing

/// One way of telling the user's clips from everyone else's: how far a clip is from the clips the
/// user picked as theirs, smaller meaning more likely theirs, or `nil` when it can't be measured.
private struct ShirtMethod {
    let name: String
    let score: (_ clip: ClipReading, _ picked: [ClipReading]) -> Float?

    static var all: [ShirtMethod] {
        [
            ShirtMethod(name: "app") { clip, picked in
                medianDistance(clip.appColor, picked.compactMap(\.appColor), lightnessWeight: LabColor.lightnessWeight)
            },
            ShirtMethod(name: "lightness-full") { clip, picked in
                medianDistance(clip.appColor, picked.compactMap(\.appColor), lightnessWeight: 1)
            },
            ShirtMethod(name: "five-moments") { clip, picked in
                medianDistance(clip.fiveMomentColor, picked.compactMap(\.fiveMomentColor), lightnessWeight: 1)
            },
            ShirtMethod(name: "top-and-legs") { clip, picked in
                guard let top = medianDistance(clip.appColor, picked.compactMap(\.appColor), lightnessWeight: 1)
                else { return nil }
                let legs = medianDistance(clip.legColor, picked.compactMap(\.legColor), lightnessWeight: 1)
                return legs.map { (top + $0) / 2 } ?? top
            },
            ShirtMethod(name: "nearest-pick") { clip, picked in
                guard let color = clip.appColor else { return nil }
                return picked.compactMap(\.appColor).map { distance(color, $0, lightnessWeight: 1) }.min()
            },
            ShirtMethod(name: "feature-print") { clip, picked in
                let theirs = picked.flatMap(\.prints)
                return clip.prints.flatMap { own in theirs.compactMap { printDistance(own, $0) } }.min()
            }
        ]
    }

    static func distance(_ lhs: LabColor, _ rhs: LabColor, lightnessWeight: Float) -> Float {
        let lightness = (lhs.lightness - rhs.lightness) / lightnessWeight
        let greenRed = lhs.greenRed - rhs.greenRed
        let blueYellow = lhs.blueYellow - rhs.blueYellow
        return (lightness * lightness + greenRed * greenRed + blueYellow * blueYellow).squareRoot()
    }

    private static func medianDistance(_ color: LabColor?, _ picked: [LabColor], lightnessWeight: Float) -> Float? {
        guard let color, let center = LabColor.median(of: picked) else { return nil }
        return distance(color, center, lightnessWeight: lightnessWeight)
    }

    private static func printDistance(_ lhs: VNFeaturePrintObservation, _ rhs: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        guard (try? lhs.computeDistance(&distance, to: rhs)) != nil else { return nil }
        return distance
    }
}

/// How one method's scores split the user's clips from everyone else's.
private struct Separation {
    let mine: [Float]
    let others: [Float]

    /// The chance a clip of the user's scores closer than one of someone else's: 1 splits them
    /// perfectly, 0.5 is a coin toss.
    var areaUnderCurve: Double? {
        guard !mine.isEmpty, !others.isEmpty else { return nil }
        var wins = 0.0
        for mineScore in mine {
            wins += others.reduce(0.0) { $0 + ($1 > mineScore ? 1 : $1 == mineScore ? 0.5 : 0) }
        }
        return wins / Double(mine.count * others.count)
    }

    /// The least threshold that keeps `share` of the user's clips, and the share of others' it keeps.
    func othersKept(keepingMine share: Double) -> (threshold: Float, others: Double)? {
        guard !mine.isEmpty, !others.isEmpty else { return nil }
        let sorted = mine.sorted()
        let threshold = sorted[max(Int((share * Double(sorted.count)).rounded(.up)) - 1, 0)]
        return (threshold, Double(others.filter { $0 <= threshold }.count) / Double(others.count))
    }
}

/// The `TURNIP_SHIRT` lines for one video.
private enum ShirtSummary {
    /// How many of the user's clips each comparison pretends they picked, earliest first.
    static let pickCounts = [1, 3]

    static func lines(for readings: [ClipReading], video: String) -> [String] {
        let mine = readings.filter(\.isMine)
        let others = readings.filter { !$0.isMine }
        var lines = [
            "\(video): \(readings.count) clips, \(mine.count) mine, \(others.count) others; top unreadable in "
                + "\(mine.filter { $0.appColor == nil }.count) of mine, \(others.filter { $0.appColor == nil }.count) "
                + "of others; app reading took \(format(readings.map(\.appSeconds).reduce(0, +))) s",
            trackLine(readings, video: video)
        ]
        for count in pickCounts {
            let picked = Array(mine.filter { $0.appColor != nil }.sorted { $0.start < $1.start }.prefix(count))
            guard picked.count == count else { continue }
            let rest = readings.filter { reading in !picked.contains { $0.start == reading.start && $0.isMine } }
            lines.append(appLine(picked: picked, rest: rest, video: video))
            lines.append(groupingLine(picked: picked, rest: rest, video: video))
            lines += ShirtMethod.all.map { methodLine($0, picked: picked, rest: rest, video: video) }
        }
        return lines
    }

    /// Whether the tracker kept people apart: a track holding both the user's clips and others'.
    private static func trackLine(_ readings: [ClipReading], video: String) -> String {
        let tracks = Dictionary(grouping: readings.filter { $0.personID != nil }, by: \.personID)
        let mixed = tracks.values.filter { track in track.contains(where: \.isMine) && track.contains { !$0.isMine } }
        return "\(video) tracks: \(tracks.count), \(mixed.count) holding both mine and others'"
    }

    /// What the app does today with these picks.
    private static func appLine(picked: [ClipReading], rest: [ClipReading], video: String) -> String {
        let sources = Dictionary(uniqueKeysWithValues: picked.compactMap { reading in
            reading.appColor.map { (UUID(), $0) }
        })
        guard let match = ShirtColorMatch(readFrom: sources) else { return "\(video) k=\(picked.count) app: no match" }
        let kept = rest.filter { $0.appColor.map(match.matches) ?? false }
        return "\(video) k=\(picked.count) app as shipped (tolerance \(format(match.tolerance))): keeps "
            + "\(kept.filter(\.isMine).count)/\(rest.filter(\.isMine).count) mine, "
            + "\(kept.filter { !$0.isMine }.count)/\(rest.filter { !$0.isMine }.count) others"
    }

    /// Keeping every clip of the picked clips' tracks, with no colour at all.
    private static func groupingLine(picked: [ClipReading], rest: [ClipReading], video: String) -> String {
        let tracks = Set(picked.compactMap(\.personID))
        let kept = rest.filter { reading in reading.personID.map { tracks.contains($0) } ?? false }
        return "\(video) k=\(picked.count) same track: keeps "
            + "\(kept.filter(\.isMine).count)/\(rest.filter(\.isMine).count) mine, "
            + "\(kept.filter { !$0.isMine }.count)/\(rest.filter { !$0.isMine }.count) others"
    }

    private static func methodLine(
        _ method: ShirtMethod, picked: [ClipReading], rest: [ClipReading], video: String
    ) -> String {
        let scored = rest.map { ($0.isMine, method.score($0, picked)) }
        let separation = Separation(
            mine: scored.filter { $0.0 }.compactMap { $0.1 }, others: scored.filter { !$0.0 }.compactMap { $0.1 })
        let unmeasured = scored.filter { $0.1 == nil }.count
        var line = "\(video) k=\(picked.count) \(method.name): AUC "
            + (separation.areaUnderCurve.map { format(Float($0)) } ?? "n/a")
        if let kept = separation.othersKept(keepingMine: 0.95) {
            line += "; keeping 95% of mine keeps \(Int((kept.others * 100).rounded()))% of others "
                + "(threshold \(format(kept.threshold)))"
        }
        return line + "; \(unmeasured) unmeasured"
    }

    static func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

// MARK: - Report

/// `results/shirt-<label>.json`: the lines, and per clip what was read and each method's score
/// against the user's earliest readable clip. No pictures.
private struct ShirtReport: Encodable {
    struct Video: Encodable {
        let video: String
        let lines: [String]
        let clips: [ClipRow]
    }

    struct ClipRow: Encodable {
        let start: Double
        let end: Double
        let personID: Int?
        let mine: Bool
        /// L*, a*, b*.
        let top: [Float]?
        let topFiveMoments: [Float]?
        let legs: [Float]?
        let featurePrints: Int
        /// Each method's score against the user's earliest readable clip.
        let scores: [String: Float]

        init(_ reading: ClipReading, among readings: [ClipReading]) {
            start = reading.start
            end = reading.end
            personID = reading.personID
            mine = reading.isMine
            top = reading.appColor.map(Self.channels)
            topFiveMoments = reading.fiveMomentColor.map(Self.channels)
            legs = reading.legColor.map(Self.channels)
            featurePrints = reading.prints.count
            let firstPick = readings.filter { $0.isMine && $0.appColor != nil }.min { $0.start < $1.start }
            scores = Dictionary(uniqueKeysWithValues: ShirtMethod.all.compactMap { method in
                firstPick.flatMap { method.score(reading, [$0]) }.map { (method.name, ($0 * 100).rounded() / 100) }
            })
        }

        private static func channels(_ color: LabColor) -> [Float] {
            [color.lightness, color.greenRed, color.blueYellow].map { ($0 * 10).rounded() / 10 }
        }
    }

    let label: String
    var videos: [Video] = []
}
