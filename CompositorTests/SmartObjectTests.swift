import AppKit
import Testing
@testable import Compositor

@MainActor
struct SmartObjectTests {
    private func asset(width: Int, height: Int, name: String, red: CGFloat) throws -> ImportedImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: name)
    }

    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.insert(try asset(width: 20, height: 10, name: "Source", red: 0.8))
        return session
    }

    @Test func convertDuplicateReplaceAndUndoShareOneSource() throws {
        let session = try session()
        session.convertActiveLayerToSmartObject()
        let contentID = try #require(session.activeLayer?.smartObjectID)
        #expect(session.document?.smartObjects.count == 1)
        #expect(!session.canPaint)
        #expect(!session.canAdjustColors)

        session.duplicateActiveLayer()
        #expect(session.document?.layers.count == 2)
        #expect(session.document?.layers.allSatisfy { $0.smartObjectID == contentID } == true)
        let transforms = try #require(session.document?.layers.map(\.transform))
        let replacement = try asset(width: 40, height: 30, name: "Replacement", red: 0.1)
        session.replaceSmartObjectContents(with: replacement)
        let layers = try #require(session.document?.layers)
        #expect(layers.allSatisfy { $0.asset?.image === replacement.image })
        #expect(layers.map(\.transform) == transforms)
        let fitted = SmartObjectGeometry.aspectFitTransform(image: replacement.image, in: transforms[0])
        #expect(abs(fitted.size.width - 13.333333) < 0.001)
        #expect(fitted.size.height == 10)
        #expect(abs(fitted.center.x - transforms[0].center.x) < 0.001)
        #expect(abs(fitted.center.y - transforms[0].center.y) < 0.001)

        session.undo()
        #expect(session.document?.layers.allSatisfy { $0.asset?.image !== replacement.image } == true)
        #expect(session.document?.layers.map(\.transform) == transforms)
        session.redo()
        #expect(session.document?.layers.allSatisfy { $0.asset?.image === replacement.image } == true)
        #expect(session.document?.layers.map(\.transform) == transforms)
    }

    @Test func viaCopyIsIndependentAndRasterizeDetachesOnlySelectedInstance() throws {
        let session = try session()
        session.convertActiveLayerToSmartObject()
        let originalLayerID = try #require(session.activeLayerID)
        let originalContentID = try #require(session.activeLayer?.smartObjectID)
        session.newSmartObjectViaCopy()
        let copiedContentID = try #require(session.activeLayer?.smartObjectID)
        #expect(copiedContentID != originalContentID)
        #expect(session.document?.smartObjects.count == 2)

        let replacement = try asset(width: 12, height: 12, name: "Independent", red: 0.3)
        session.replaceSmartObjectContents(with: replacement)
        #expect(session.activeLayer?.asset?.image === replacement.image)
        #expect(session.document?.layers.first(where: { $0.id == originalLayerID })?.asset?.image !== replacement.image)

        session.rasterizeActiveSmartObject()
        #expect(session.activeLayer?.smartObjectID == nil)
        #expect(session.activeLayer?.asset?.image === replacement.image)
        #expect(session.document?.smartObjects[copiedContentID] == nil)
        #expect(session.document?.smartObjects[originalContentID] != nil)
        #expect(session.canPaint)
    }

    @Test func replacementRendersContainedWithoutStretching() async throws {
        let session = try session()
        session.convertActiveLayerToSmartObject()
        session.replaceSmartObjectContents(with: try asset(width: 40, height: 30,
                                                            name: "Portrait replacement", red: 0.4))
        let result = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let read = try #require(CGContext(data: nil, width: result.width, height: result.height,
            bitsPerComponent: 8, bytesPerRow: result.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        read.draw(result, in: CGRect(x: 0, y: 0, width: result.width, height: result.height))
        let bytes = try #require(read.data).assumingMemoryBound(to: UInt8.self)
        func alpha(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * result.width + x) * 4 + 3]) }
        #expect(alpha(0, 5) == 0)       // transparent space left by contain fitting
        #expect(alpha(10, 5) == 255)    // replacement remains centered and visible
        #expect(alpha(19, 5) == 0)
    }

    @Test func projectRoundTripStoresSharedContentOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorSmartObjectTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try session()
        session.convertActiveLayerToSmartObject()
        session.duplicateActiveLayer()
        let url = root.appendingPathComponent("Shared.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)

        let files = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("smart-objects").path)
        #expect(files.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("images").path).isEmpty)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == 9)
        #expect(loaded.smartObjects.count == 1)
        #expect(loaded.manifest.layers.count == 2)
        #expect(loaded.manifest.layers.allSatisfy { $0.imageFile == nil && $0.smartObjectID != nil })
        let first = try #require(loaded.images[loaded.manifest.layers[0].id]?.image)
        let second = try #require(loaded.images[loaded.manifest.layers[1].id]?.image)
        #expect(first === second)
    }

    @Test func freeDistortStoresAnEditableInstanceFrameWithoutChangingSourcePixels() throws {
        let session = try session()
        session.convertActiveLayerToSmartObject()
        let source = try #require(session.activeLayer?.asset?.image)
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 10, y: 10),
            size: CGSize(width: 40, height: 20))
        let corners = [CGPoint(x: 8, y: 12), CGPoint(x: 54, y: 7),
                       CGPoint(x: 48, y: 34), CGPoint(x: 12, y: 29)]

        session.selectTool(.move)
        session.beginTransform(persistent: false)
        session.beginDistort()
        session.previewCorners(corners)
        session.commitTransform()

        #expect(session.activeLayer?.smartObjectCorners == corners)
        #expect(session.activeLayer?.asset?.image === source)
        #expect(session.activeLayer?.transform == LayerTransform(origin: CGPoint(x: 10, y: 10),
            size: CGSize(width: 40, height: 20)))

        session.undo()
        #expect(session.activeLayer?.smartObjectCorners == nil)
        #expect(session.activeLayer?.asset?.image === source)
        session.redo()
        #expect(session.activeLayer?.smartObjectCorners == corners)
    }

    @Test func projectRoundTripPreservesPerspectiveFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompositorSmartWarpTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try session()
        session.convertActiveLayerToSmartObject()
        let corners = [CGPoint(x: 1, y: 1), CGPoint(x: 19, y: 2),
                       CGPoint(x: 18, y: 9), CGPoint(x: 2, y: 8)]
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].smartObjectCorners = corners
        let url = root.appendingPathComponent("Warped.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.first?.smartObjectCorners == corners)
    }
}
