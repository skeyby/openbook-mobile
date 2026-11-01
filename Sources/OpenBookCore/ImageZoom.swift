import Foundation
import CoreGraphics

/// Geometry only: shared zoom bounds without depending on SwiftUI or loading media.
public struct ImageZoom: Equatable, Sendable {
    public private(set) var scale: CGFloat = 1
    public private(set) var offset: CGSize = .zero
    public var isZoomed: Bool { scale > 1 }
    public init() { }

    /// Anchor is measured from the viewport centre, in unscaled points.
    public mutating func magnify(to requestedScale: CGFloat, anchor: CGPoint = .zero,
                                 imageSize: CGSize, viewport: CGSize) {
        guard requestedScale.isFinite else { return }
        let next = min(6, max(1, requestedScale))
        let ratio = next / scale
        offset = CGSize(width: offset.width * ratio + anchor.x * (1 - ratio),
                        height: offset.height * ratio + anchor.y * (1 - ratio))
        scale = next < 1.01 ? 1 : next
        constrain(imageSize: imageSize, viewport: viewport)
    }

    public mutating func pan(from start: CGSize, translation: CGSize, imageSize: CGSize, viewport: CGSize) {
        guard isZoomed else { return }
        offset = CGSize(width: start.width + translation.width, height: start.height + translation.height)
        constrain(imageSize: imageSize, viewport: viewport)
    }

    /// imageSize is the aspect-fit image before zoom, not the entire letterboxed viewport.
    public mutating func constrain(imageSize: CGSize, viewport: CGSize) {
        guard isZoomed else { offset = .zero; return }
        let x = max(0, (imageSize.width * scale - viewport.width) / 2)
        let y = max(0, (imageSize.height * scale - viewport.height) / 2)
        offset.width = min(x, max(-x, offset.width))
        offset.height = min(y, max(-y, offset.height))
    }

    public mutating func reset() { self = ImageZoom() }
}
