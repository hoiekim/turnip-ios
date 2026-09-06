import Foundation

/// The hand-off from Home to whatever consumes the picked video — the pose diagnostic today, the
/// Processing screen (#17) once it exists. A file URL rather than a `PHAsset`, because a URL is
/// what `VideoFrameSampler.sampleFrames(from:)` reads and it keeps PhotoKit out of the pipeline.
///
/// `Hashable` so it can be a `NavigationStack` path element.
struct SelectedVideo: Hashable {
    /// `PHAsset.localIdentifier` of the source, kept so later screens can re-fetch metadata or
    /// write results back next to the original.
    let assetIdentifier: String
    /// Readable file URL. For ordinary Photos videos this points into the Photos library itself;
    /// for compositions (slow-motion, edited) it's a temp-file export — see `PhotoVideoResolver`.
    let url: URL
    let duration: TimeInterval
}
