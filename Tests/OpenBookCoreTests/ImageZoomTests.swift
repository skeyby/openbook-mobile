import Foundation
import CoreGraphics
import Testing
@testable import OpenBookCore

@Suite struct ImageZoomTests {
    @Test func landscapeImageCannotBeDraggedIntoEmptyVerticalSpace() {
        let image = CGSize(width: 400, height: 200)
        let viewport = CGSize(width: 400, height: 800)
        var zoom = ImageZoom()
        zoom.magnify(to: 2, imageSize: image, viewport: viewport)
        zoom.pan(from: .zero, translation: CGSize(width: 900, height: 900), imageSize: image, viewport: viewport)
        #expect(zoom.offset == CGSize(width: 200, height: 0))
        zoom.pan(from: .zero, translation: CGSize(width: -900, height: -900), imageSize: image, viewport: viewport)
        #expect(zoom.offset == CGSize(width: -200, height: 0))
    }

    @Test func portraitImageOnlyPansWhereItExceedsTheViewport() {
        let image = CGSize(width: 100, height: 800)
        let viewport = CGSize(width: 400, height: 800)
        var zoom = ImageZoom()
        zoom.magnify(to: 3, imageSize: image, viewport: viewport)
        zoom.pan(from: .zero, translation: CGSize(width: 300, height: 1200), imageSize: image, viewport: viewport)
        #expect(zoom.offset == CGSize(width: 0, height: 800))
    }

    @Test func zoomPreservesThePointUnderThePinchAnchor() {
        let size = CGSize(width: 400, height: 400)
        var zoom = ImageZoom()
        zoom.magnify(to: 2, anchor: CGPoint(x: 100, y: 0), imageSize: size, viewport: size)
        #expect(zoom.offset == CGSize(width: -100, height: 0))
        zoom.magnify(to: 4, anchor: CGPoint(x: 100, y: 0), imageSize: size, viewport: size)
        #expect(zoom.offset == CGSize(width: -300, height: 0))
    }

    @Test func minimumMaximumAndResetAreBounded() {
        let size = CGSize(width: 400, height: 400)
        var zoom = ImageZoom()
        zoom.magnify(to: 40, imageSize: size, viewport: size)
        #expect(zoom.scale == 6 && zoom.isZoomed)
        zoom.pan(from: .zero, translation: CGSize(width: 50, height: 60), imageSize: size, viewport: size)
        zoom.magnify(to: 1.005, imageSize: size, viewport: size)
        #expect(zoom == ImageZoom())
        zoom.magnify(to: -10, imageSize: size, viewport: size)
        #expect(zoom == ImageZoom())
        zoom.magnify(to: 3, imageSize: size, viewport: size)
        zoom.reset()
        #expect(zoom == ImageZoom())
    }

    @Test func rotationReclampsOffsetsWithoutResettingZoom() {
        var zoom = ImageZoom()
        zoom.magnify(to: 2, imageSize: CGSize(width: 400, height: 800), viewport: CGSize(width: 400, height: 800))
        zoom.pan(from: .zero, translation: CGSize(width: 200, height: 400),
                 imageSize: CGSize(width: 400, height: 800), viewport: CGSize(width: 400, height: 800))
        zoom.constrain(imageSize: CGSize(width: 200, height: 400), viewport: CGSize(width: 800, height: 400))
        #expect(zoom.scale == 2)
        #expect(zoom.offset == CGSize(width: 0, height: 200))
    }

    @Test func nonFiniteMagnificationDoesNotCorruptTheTransform() {
        var zoom = ImageZoom()
        zoom.magnify(to: .infinity, imageSize: .zero, viewport: .zero)
        zoom.magnify(to: .nan, imageSize: .zero, viewport: .zero)
        #expect(zoom == ImageZoom())
    }
}
