import Foundation
import Photos
import PhotosUI
import UIKit

/// Backs Home: Photos authorization, the video `PHAsset` list, and turning a tapped tile into a
/// `SelectedVideo` pushed onto the navigation path.
@MainActor
final class VideoLibraryViewModel: ObservableObject {
    /// A tile tap in progress. `downloadProgress` is nil until PhotoKit reports the first iCloud
    /// progress callback — local assets resolve without ever setting it.
    struct Resolution: Equatable {
        let assetIdentifier: String
        var downloadProgress: Double?
    }

    @Published private(set) var authorization: PhotoLibraryAuthorization
    /// Newest first. Materialized from the `PHFetchResult` because `ForEach` wants a collection
    /// with stable IDs; `PHAsset` objects are lightweight faults, so this is cheap even for a
    /// large library — the expensive part (thumbnails) is loaded lazily per visible tile.
    @Published private(set) var videos: [PHAsset] = []
    @Published private(set) var resolution: Resolution?
    @Published var errorMessage: String?
    @Published var path: [SelectedVideo] = []

    /// Shared by every tile so thumbnails stay cached across scrolls and grid reloads.
    let thumbnailManager: PHCachingImageManager = {
        let manager = PHCachingImageManager()
        manager.allowsCachingHighQualityImages = false
        return manager
    }()

    private let library: PHPhotoLibrary
    private let resolver: PhotoVideoResolver
    private var fetchResult: PHFetchResult<PHAsset>?
    private var changeForwarder: PhotoLibraryChangeForwarder?
    private var resolveTask: Task<Void, Never>?

    init(library: PHPhotoLibrary = .shared(), resolver: PhotoVideoResolver = PhotoVideoResolver()) {
        self.library = library
        self.resolver = resolver
        authorization = PhotoLibraryAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    deinit {
        if let changeForwarder {
            library.unregisterChangeObserver(changeForwarder)
        }
    }

    // MARK: - Authorization + loading

    /// Prompts for access on first launch, then loads the grid. Safe to call again — a second
    /// call after a prompt just reloads.
    ///
    /// `.readWrite` rather than a read-only level because PhotoKit has none: the choices are
    /// add-only (can't enumerate) or read/write. Export (#10) needs the write half anyway.
    func start() async {
        if authorization == .notDetermined {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            authorization = PhotoLibraryAuthorization(status)
        }
        reload()
    }

    func reload() {
        guard authorization.canReadLibrary else {
            videos = []
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .video, options: options)
        fetchResult = result
        videos = result.objects(at: IndexSet(integersIn: 0..<result.count))
        observeLibraryChanges()
    }

    /// Limited-access affordance: iOS's own picker for extending the granted subset. Presented
    /// from UIKit because SwiftUI has no wrapper for it.
    func presentLimitedLibraryPicker() {
        guard let presenter = UIApplication.shared.topViewController else { return }
        library.presentLimitedLibraryPicker(from: presenter) { [weak self] _ in
            // The change observer fires too, but the completion is the deterministic signal.
            Task { @MainActor in self?.reload() }
        }
    }

    private func observeLibraryChanges() {
        guard changeForwarder == nil else { return }
        let forwarder = PhotoLibraryChangeForwarder { [weak self] change in
            Task { @MainActor in self?.apply(change) }
        }
        library.register(forwarder)
        changeForwarder = forwarder
    }

    private func apply(_ change: PHChange) {
        guard let fetchResult, let details = change.changeDetails(for: fetchResult) else { return }
        let updated = details.fetchResultAfterChanges
        self.fetchResult = updated
        videos = updated.objects(at: IndexSet(integersIn: 0..<updated.count))
    }

    // MARK: - Selection

    /// Resolves the tapped asset to a file and pushes it onto `path`. One at a time: tiles are
    /// disabled while a resolution is in flight, and `cancelSelection()` aborts it.
    func select(_ asset: PHAsset) {
        guard resolution == nil else { return }
        errorMessage = nil
        resolution = Resolution(assetIdentifier: asset.localIdentifier, downloadProgress: nil)

        resolveTask = Task {
            defer { resolution = nil }
            do {
                let url = try await resolver.resolve(asset) { progress in
                    Task { @MainActor in self.resolution?.downloadProgress = progress }
                }
                guard !Task.isCancelled else { return }
                path.append(SelectedVideo(assetIdentifier: asset.localIdentifier, url: url, duration: asset.duration))
            } catch is CancellationError {
                // User backed out; nothing to report.
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancelSelection() {
        resolveTask?.cancel()
    }
}

private extension UIApplication {
    /// The view controller to present the limited-library picker from: the foreground scene's
    /// key window root, following any presentation chain to the top.
    var topViewController: UIViewController? {
        let scene = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
