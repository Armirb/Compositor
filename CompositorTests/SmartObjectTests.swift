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
        let centers = try #require(session.document?.layers.map(\.transform.center))
        let replacement = try asset(width: 40, height: 30, name: "Replacement", red: 0.1)
        session.replaceSmartObjectContents(with: replacement)
        let layers = try #require(session.document?.layers)
        #expect(layers.allSatisfy { $0.asset?.image === replacement.image })
        #expect(layers.map(\.transform.center) == centers)
        #expect(layers.allSatisfy { $0.transform.size == CGSize(width: 40, height: 30) })

        session.undo()
        #expect(session.document?.layers.allSatisfy { $0.asset?.image !== replacement.image } == true)
        #expect(session.document?.layers.allSatisfy { $0.transform.size == CGSize(width: 20, height: 10) } == true)
        session.redo()
        #expect(session.document?.layers.allSatisfy { $0.asset?.image === replacement.image } == true)
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
        #expect(loaded.manifest.version == 8)
        #expect(loaded.smartObjects.count == 1)
        #expect(loaded.manifest.layers.count == 2)
        #expect(loaded.manifest.layers.allSatisfy { $0.imageFile == nil && $0.smartObjectID != nil })
        let first = try #require(loaded.images[loaded.manifest.layers[0].id]?.image)
        let second = try #require(loaded.images[loaded.manifest.layers[1].id]?.image)
        #expect(first === second)
    }
}
