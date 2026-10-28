import AVFoundation
import Photos
import SwiftUI

/// A saved clip's video, reached in Photos by its `exportAssetID`. A clip whose video was deleted
/// in Photos keeps its record (`docs/PROFILE_DESIGN.md` §2.3), so every read here can find nothing.
enum LibraryClipMedia {
    static func asset(for clip: LibraryClip) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [clip.exportAssetID], options: nil).firstObject
    }

    /// One final-quality frame, filling `pixelSize`.
    static func thumbnail(for asset: PHAsset, pixelSize: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: pixelSize, contentMode: .aspectFill, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// The video to play, downloaded from iCloud when Photos keeps only a preview on the device.
    static func video(for asset: PHAsset) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .automatic
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, _ in
                continuation.resume(returning: video)
            }
        }
    }
}

/// A saved clip's still: its first frame from Photos, or a "not in Photos" glyph once the video is
/// gone. Fills whatever frame its caller gives it.
struct LibraryClipThumbnail: View {
    let clip: LibraryClip

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var isMissing = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.quaternarySystemFill)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if isMissing {
                    Image(systemName: "video.slash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .task(id: clip.exportAssetID) {
                guard let asset = LibraryClipMedia.asset(for: clip) else {
                    isMissing = true
                    return
                }
                let side = max(proxy.size.width, proxy.size.height) * displayScale
                image = await LibraryClipMedia.thumbnail(for: asset, pixelSize: CGSize(width: side, height: side))
            }
        }
    }
}

/// Loops a saved clip's video, muted, over its still until the first frame is ready. Plays on its
/// own only where the system allows auto-playing loops (`mayAutoplayVideoLoops`); otherwise it
/// waits on its first frame for the play button.
struct LibraryClipPlayer: View {
    let clip: LibraryClip
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// False for a page beside the current one: its loop is built, paused.
    var isActive = true

    @StateObject private var playback = LibraryClipPlayback()
    @State private var isReady = false

    var body: some View {
        ZStack {
            if !isReady {
                LibraryClipThumbnail(clip: clip)
            }
            if let player = playback.player {
                BareVideoPlayerView(player: player, videoGravity: videoGravity, onReadyForDisplay: { isReady = true })
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if playback.player != nil {
                ScrimIconButton(
                    systemImage: playback.isPlaying ? "pause.fill" : "play.fill",
                    accessibilityLabel: playback.isPlaying ? "Pause" : "Play",
                    diameter: 36,
                    font: .footnote.weight(.bold)
                ) {
                    playback.toggle()
                }
                .padding(8)
                .accessibilityIdentifier("clip-play-pause")
            }
        }
        .task(id: clip.exportAssetID) {
            isReady = false
            await playback.load(clip, autoplay: isActive)
        }
        .onChange(of: isActive) { active in
            if active { playback.playIfAllowed() } else { playback.pause() }
        }
        .onDisappear { playback.teardown() }
    }
}

/// The loop behind `LibraryClipPlayer`.
@MainActor
final class LibraryClipPlayback: ObservableObject {
    @Published private(set) var player: AVQueuePlayer?
    @Published private(set) var isPlaying = false

    private var looper: AVPlayerLooper?
    private let mayAutoplayLoops: @MainActor () -> Bool

    init(mayAutoplayLoops: @escaping @MainActor () -> Bool = {
        mayAutoplayVideoLoops(
            isVideoAutoplayEnabled: UIAccessibility.isVideoAutoplayEnabled,
            isReduceMotionEnabled: UIAccessibility.isReduceMotionEnabled)
    }) {
        self.mayAutoplayLoops = mayAutoplayLoops
    }

    func load(_ clip: LibraryClip, autoplay: Bool) async {
        teardown()
        guard let asset = LibraryClipMedia.asset(for: clip),
              let video = await LibraryClipMedia.video(for: asset),
              !Task.isCancelled
        else { return }
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        looper = AVPlayerLooper(player: queuePlayer, templateItem: AVPlayerItem(sdrAsset: video))
        player = queuePlayer
        if autoplay { playIfAllowed() }
    }

    func playIfAllowed() {
        guard mayAutoplayLoops() else { return }
        play()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        player?.play()
        isPlaying = player != nil
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func teardown() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        isPlaying = false
    }
}
