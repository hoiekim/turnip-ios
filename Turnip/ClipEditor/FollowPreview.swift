import AVFoundation
import QuartzCore
import SwiftUI
import UIKit

/// A follow crop's movement in the editor's preview: how far the picture is shifted, in the
/// source's displayed pixels, at each frame the player can show — the crop's center moved
/// onto the clip's crop center, before the zoom and turn apply about it.
///
/// The shift steps once per source frame, on the frame's own presentation time: the preview
/// moves the picture with the frame it shows (`EditorPlayerView`).
struct FollowPan: Equatable {
    /// The shift before the first step.
    let initial: CGPoint
    /// Each step's frame time and the shift from then on, in time order.
    let steps: [(time: TimeInterval, shift: CGPoint)]

    /// `frames` are the presentation times across the crop's moving span
    /// (`VideoFrameTimes.frames(across:)`); a crop that never moves has no steps.
    init(crop: FollowCrop, cropCenter: CGPoint, frames: [TimeInterval]) {
        let path = crop.path
        func shift(at time: TimeInterval) -> CGPoint {
            let center = path.center(at: time)
            return CGPoint(x: cropCenter.x - center.x, y: cropCenter.y - center.y)
        }
        initial = shift(at: path.movingSpan?.lowerBound ?? 0)
        steps = path.movingSpan == nil ? [] : frames.map { ($0, shift(at: $0)) }
    }

    private init(initial: CGPoint, steps: [(time: TimeInterval, shift: CGPoint)]) {
        self.initial = initial
        self.steps = steps
    }

    func shift(at time: TimeInterval) -> CGPoint {
        steps.last { $0.time <= time }?.shift ?? initial
    }

    /// The same pan with the picture moved a further `offset` at every moment.
    func moved(by offset: CGPoint) -> FollowPan {
        func move(_ shift: CGPoint) -> CGPoint { CGPoint(x: shift.x + offset.x, y: shift.y + offset.y) }
        return FollowPan(initial: move(initial), steps: steps.map { ($0.time, move($0.shift)) })
    }

    static func == (lhs: FollowPan, rhs: FollowPan) -> Bool {
        lhs.initial == rhs.initial
            && lhs.steps.count == rhs.steps.count
            && zip(lhs.steps, rhs.steps).allSatisfy { $0.time == $1.time && $0.shift == $1.shift }
    }
}

/// How much of each pan the preview draws, keyed by the pan's generation
/// (`PreviewPanBlend.pans`). At rest one generation has all of it; an ease
/// (`docs/UIUX.md` § "An automatic change moves, it never cuts") hands it to a new generation
/// along SwiftUI's own animation of this value, in the same transaction that animates the zoom
/// and the turn, so SwiftUI interpolates the pan's ease and the zoom's on the same frame by the
/// same curve — an ease that interrupts another included, since SwiftUI adds the animations of a
/// vector value the way it adds a scale's.
struct PreviewPanWeights: VectorArithmetic {
    /// A missing generation weighs nothing.
    private(set) var values: [Int: Double]

    init(_ values: [Int: Double] = [:]) {
        self.values = values.filter { $0.value != 0 }
    }

    static var zero: PreviewPanWeights { PreviewPanWeights() }

    static func + (lhs: PreviewPanWeights, rhs: PreviewPanWeights) -> PreviewPanWeights {
        PreviewPanWeights(lhs.values.merging(rhs.values, uniquingKeysWith: +))
    }

    static func - (lhs: PreviewPanWeights, rhs: PreviewPanWeights) -> PreviewPanWeights {
        PreviewPanWeights(lhs.values.merging(rhs.values.mapValues { -$0 }, uniquingKeysWith: +))
    }

    mutating func scale(by rhs: Double) {
        self = PreviewPanWeights(values.mapValues { $0 * rhs })
    }

    var magnitudeSquared: Double {
        values.values.reduce(0) { $0 + $1 * $1 }
    }
}

/// What the preview moves the picture by: a blend of follow pans, `nil` among them meaning the
/// picture unshifted, as Still draws it. The shift is worked out for the frame on screen at its
/// own presentation time, so the pan never steps on a different refresh from its frame.
struct PreviewPanBlend: Equatable {
    /// The pans by generation; a generation without one draws the picture unshifted.
    var pans: [Int: FollowPan]
    var weights: PreviewPanWeights

    /// The picture's shift for the frame presented at `time`, in displayed pixels.
    func shift(at time: TimeInterval) -> CGPoint {
        weights.values.reduce(into: CGPoint.zero) { sum, entry in
            guard let shift = pans[entry.key]?.shift(at: time) else { return }
            sum.x += shift.x * entry.value
            sum.y += shift.y * entry.value
        }
    }
}

/// The editor's video frames, taken from the player item one display refresh at a time and handed
/// to the views that show them (`EditorPlayerView`) — the editor's stage and the expansion
/// flight's card.
///
/// The frames don't go to an `AVPlayerLayer`: a player layer's frame reaches the screen on the
/// render server's schedule, off the item's clock, while the zoom, the turn and the pan's ease are
/// SwiftUI animations committed by the app, and the two land one to four display refreshes apart
/// on an iPhone, differently on every ease (`docs/DESIGN.md` step 6, "Editor preview"). Here the
/// frame due at the next refresh becomes a layer's contents in the same Core Animation transaction
/// as its pan, and SwiftUI's frame carries the zoom, the turn and the pan's weights, so the whole
/// picture reaches the screen in one commit.
@MainActor
final class PreviewFrames {
    /// The output's frames are drawn no larger than this on their long side: past it, the preview
    /// can't show the detail at the editor's zoom range, and the buffers are held in the app.
    static let maximumDimension: CGFloat = 1920

    /// The frame shown now, and its presentation time on the item's clock.
    private(set) var latest: (buffer: CVPixelBuffer, time: TimeInterval)?
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var link: CADisplayLink?
    private var views: [WeakView] = []

    private struct WeakView {
        weak var view: EditorPlayerView.PlayerContainerView?
    }

    /// Takes frames from `item` from now on, at `naturalSize` (the encoded frame's, in pixels)
    /// scaled within `maximumDimension`.
    func attach(to item: AVPlayerItem, naturalSize: CGSize) {
        if let output, let attached = self.item {
            attached.remove(output)
        }
        self.item = item
        let scale = min(1, Self.maximumDimension / max(naturalSize.width, naturalSize.height, 1))
        var settings: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
            // Rec. 709 only, so an HDR take arrives tone mapped to SDR, as the app's other players
            // show it (`AVPlayerItem(sdrAsset:)`).
            AVVideoAllowWideColorKey: false
        ]
        if scale < 1 {
            settings[kCVPixelBufferWidthKey as String] = Int((naturalSize.width * scale).rounded())
            settings[kCVPixelBufferHeightKey as String] = Int((naturalSize.height * scale).rounded())
        }
        let output = AVPlayerItemVideoOutput(outputSettings: settings)
        item.add(output)
        self.output = output
        latest = nil
    }

    func register(_ view: EditorPlayerView.PlayerContainerView) {
        views.removeAll { $0.view == nil || $0.view === view }
        views.append(WeakView(view: view))
        if let latest {
            view.show(latest.buffer, at: latest.time)
        }
        startLink()
    }

    func unregister(_ view: EditorPlayerView.PlayerContainerView) {
        views.removeAll { $0.view == nil || $0.view === view }
        if views.isEmpty {
            link?.invalidate()
            link = nil
        }
    }

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget { [weak self] link in self?.step(link) },
                                 selector: #selector(DisplayLinkTarget.fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Takes the frame due at the refresh this one prepares, if it's new, and shows it.
    private func step(_ link: CADisplayLink) {
        guard let output else { return }
        let itemTime = output.itemTime(forHostTime: link.targetTimestamp)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var presentationTime = CMTime.zero
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &presentationTime),
              presentationTime.isNumeric
        else { return }
        latest = (buffer, presentationTime.seconds)
        for entry in views {
            entry.view?.show(buffer, at: presentationTime.seconds)
        }
    }
}

/// A display link's target that runs a closure on each refresh.
@MainActor
final class DisplayLinkTarget: NSObject {
    private let action: (CADisplayLink) -> Void

    init(_ action: @escaping (CADisplayLink) -> Void) {
        self.action = action
    }

    @objc func fire(_ link: CADisplayLink) {
        action(link)
    }
}

/// The editor's video: the frames `PreviewFrames` hands it, each moved by the pan for its own
/// presentation time (`PreviewPanBlend`), laid out so the unshifted frame sits exactly on the
/// view's bounds. Shared by the editor's stage and the expansion flight's card.
///
/// `animatableData` is the pan's weights, so SwiftUI hands this view each step of an ease in the
/// same frame as the zoom and the turn it applies around it.
struct EditorPlayerView: View, Animatable {
    let frames: PreviewFrames
    /// The source track's geometry, for the encoded frame's size and orientation; `nil` until
    /// media info has loaded.
    let track: VideoTrackGeometry?
    var pan: PreviewPanBlend
    var onReadyForDisplay: (() -> Void)?

    var animatableData: PreviewPanWeights {
        get { pan.weights }
        set { pan.weights = newValue }
    }

    var body: some View {
        Representable(frames: frames, track: track, pan: pan, onReadyForDisplay: onReadyForDisplay)
    }

    private struct Representable: UIViewRepresentable {
        let frames: PreviewFrames
        let track: VideoTrackGeometry?
        let pan: PreviewPanBlend
        let onReadyForDisplay: (() -> Void)?

        func makeUIView(context: Context) -> PlayerContainerView {
            let view = PlayerContainerView(frames: frames)
            updateUIView(view, context: context)
            return view
        }

        func updateUIView(_ view: PlayerContainerView, context: Context) {
            view.onReadyForDisplay = onReadyForDisplay
            view.update(track: track, pan: pan)
        }
    }

    final class PlayerContainerView: UIView {
        var onReadyForDisplay: (() -> Void)?
        private let frames: PreviewFrames
        private let videoLayer = CALayer()
        private var track: VideoTrackGeometry?
        private var pan = PreviewPanBlend(pans: [:], weights: .zero)
        private var frameTime: TimeInterval?
        /// The frame shown and the one before it, kept until replaced: the render server may
        /// still be drawing the earlier one when the next arrives.
        private var heldBuffers: [CVPixelBuffer] = []
        private var hasShownFrame = false

        init(frames: PreviewFrames) {
            self.frames = frames
            super.init(frame: .zero)
            videoLayer.contentsGravity = .resize
            videoLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
            layer.addSublayer(videoLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                frames.register(self)
            } else {
                frames.unregister(self)
            }
        }

        func update(track: VideoTrackGeometry?, pan: PreviewPanBlend) {
            guard track != self.track || pan != self.pan else { return }
            self.track = track
            self.pan = pan
            placeVideo()
        }

        /// Shows `buffer`, presented at `time`, with the pan for that time.
        func show(_ buffer: CVPixelBuffer, at time: TimeInterval) {
            heldBuffers = [buffer] + heldBuffers.prefix(1)
            frameTime = time
            videoLayer.contents = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
            placeVideo()
            if !hasShownFrame {
                hasShownFrame = true
                DispatchQueue.main.async { [weak self] in self?.onReadyForDisplay?() }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            placeVideo()
        }

        /// Moves the video layer by the pan for the frame it shows. Never in a transaction of its
        /// own: an explicit transaction that isn't nested commits on the spot, which can reach the
        /// screen a refresh ahead of the zoom SwiftUI commits for the same frame. The changes ride
        /// whatever transaction is open, SwiftUI's own while it calls `update`, and `actions`
        /// keeps them from animating.
        private func placeVideo() {
            guard let track else { return }
            // A hair past the frame's own time, so a rounding below it never draws the frame
            // with the step before.
            let shift = frameTime.map { pan.shift(at: $0 + 0.0005) } ?? .zero
            let placement = EditorVideoPlacement(track: track, bounds: bounds, shift: shift)
            videoLayer.bounds = placement.bounds
            videoLayer.position = placement.position
            videoLayer.setAffineTransform(placement.transform)
        }
    }
}

/// Where the editor's video layer goes in its view: the encoded frame, at the view's points per
/// displayed pixel, turned upright about its center by the track's own transform, centered on
/// the view moved by `shift` (displayed pixels), so the unshifted upright frame fills `bounds`.
struct EditorVideoPlacement: Equatable {
    let bounds: CGRect
    let position: CGPoint
    let transform: CGAffineTransform

    init(track: VideoTrackGeometry, bounds viewBounds: CGRect, shift: CGPoint) {
        let displayed = track.displayedSize
        let scale = displayed.width > 0 ? viewBounds.width / displayed.width : 0
        bounds = CGRect(
            x: 0, y: 0, width: track.naturalSize.width * scale, height: track.naturalSize.height * scale)
        position = CGPoint(x: viewBounds.midX + shift.x * scale, y: viewBounds.midY + shift.y * scale)
        let turn = track.preferredTransform
        transform = CGAffineTransform(a: turn.a, b: turn.b, c: turn.c, d: turn.d, tx: 0, ty: 0)
    }
}
