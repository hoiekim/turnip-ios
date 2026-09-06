import Photos
import SwiftUI

/// One square cell in the Home grid: cached thumbnail, duration badge, and — while this tile's
/// video is being fetched — a progress overlay (a determinate ring during an iCloud download, a
/// spinner otherwise).
struct VideoTileView: View {
    let asset: PHAsset
    let imageManager: PHImageManager
    let resolution: VideoLibraryViewModel.Resolution?

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    private var isResolving: Bool {
        resolution?.assetIdentifier == asset.localIdentifier
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(.secondarySystemFill)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear { load(targetSize: proxy.size) }
            .onDisappear(perform: cancel)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) { durationBadge }
        .overlay { if isResolving { resolvingOverlay } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    private var durationBadge: some View {
        Text(VideoDurationFormatter.string(from: asset.duration))
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 2)
            .padding(4)
    }

    private var resolvingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
            if let progress = resolution?.downloadProgress {
                ProgressRing(progress: progress)
                    .frame(width: 36, height: 36)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
    }

    private var accessibilityDescription: String {
        var parts = ["Video", VideoDurationFormatter.string(from: asset.duration)]
        if let creationDate = asset.creationDate {
            parts.append(creationDate.formatted(date: .abbreviated, time: .shortened))
        }
        if isResolving {
            parts.append("loading")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Thumbnail loading

    private func load(targetSize: CGSize) {
        guard image == nil, requestID == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let pixelSize = CGSize(width: targetSize.width * displayScale, height: targetSize.height * displayScale)

        requestID = imageManager.requestImage(
            for: asset, targetSize: pixelSize, contentMode: .aspectFill, options: options
        ) { result, info in
            // Opportunistic delivery may call back twice (degraded, then final); keep whichever is latest.
            if let result {
                image = result
            }
            if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                requestID = nil
            }
        }
    }

    private func cancel() {
        if let requestID {
            imageManager.cancelImageRequest(requestID)
        }
        requestID = nil
    }
}

/// iOS has no determinate circular `ProgressView` style, so draw one.
private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
        }
    }
}
