import AppKit

/// One embedded raster source shared by one or more layer instances.
/// The asset is immutable; replacing it installs a new value so document history can share old pixels cheaply.
nonisolated struct SmartObjectContent: Equatable, @unchecked Sendable {
    let id: UUID
    var asset: ImportedImage

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.asset.image === rhs.asset.image && lhs.asset.thumbnail === rhs.asset.thumbnail
            && lhs.asset.name == rhs.asset.name
    }
}

extension ImageLayer {
    var isSmartObject: Bool { smartObjectID != nil }
}

extension CanvasDocument {
    /// Image-pixel budget with shared Smart Object contents counted once rather than once per instance.
    func sourcePixelCount(excludingSmartObject excluded: UUID? = nil) -> Int {
        let rasterPixels = layers.reduce(0) { total, layer in
            guard layer.smartObjectID == nil, let image = layer.asset?.image else { return total }
            return total + image.width * image.height
        }
        return smartObjects.reduce(rasterPixels) { total, entry in
            guard entry.key != excluded else { return total }
            let image = entry.value.asset.image
            return total + image.width * image.height
        }
    }

    mutating func pruneUnusedSmartObjects() {
        let used = Set(layers.compactMap(\.smartObjectID))
        smartObjects = smartObjects.filter { used.contains($0.key) }
    }
}

extension EditorSession {
    var canConvertToSmartObject: Bool {
        canEditLayers && selectedLayerIDs.count == 1 && !isMaskSelected
            && activeLayer?.isGroup == false && activeLayer?.adjustment == nil
            && activeLayer?.asset != nil && activeLayer?.smartObjectID == nil
    }
    var canRasterizeSmartObject: Bool {
        canEditLayers && selectedLayerIDs.count == 1 && !isMaskSelected && activeLayer?.smartObjectID != nil
    }
    var canReplaceSmartObjectContents: Bool { canRasterizeSmartObject }

    func convertActiveLayerToSmartObject() {
        guard canConvertToSmartObject, let index = document?.layers.firstIndex(where: { $0.id == activeLayerID }),
              let asset = document?.layers[index].asset else { return }
        let id = UUID()
        beginEdit("Convert to Smart Object")
        document?.smartObjects[id] = SmartObjectContent(id: id, asset: asset)
        document?.layers[index].smartObjectID = id
        // A shape becomes the embedded pixels visible at conversion time; it no longer redraws independently.
        document?.layers[index].shape = nil
        endEdit()
    }

    /// Ordinary duplication shares a Smart Object source. This command deliberately makes an independent source.
    func newSmartObjectViaCopy() {
        guard canRasterizeSmartObject, let document, let layer = activeLayer,
              let sourceID = layer.smartObjectID, let source = document.smartObjects[sourceID],
              let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        let contentID = UUID()
        let copy = ImageLayer(id: UUID(), asset: source.asset, name: "\(layer.name) copy", isVisible: layer.isVisible,
            transform: layer.transform, parentID: layer.parentID, isGroup: false, opacity: layer.opacity,
            blendMode: layer.blendMode, mask: layer.mask, maskSourceID: layer.maskSourceID,
            smartObjectID: contentID)
        beginEdit("New Smart Object via Copy")
        self.document?.smartObjects[contentID] = SmartObjectContent(id: contentID, asset: source.asset)
        self.document?.layers.insert(copy, at: index + 1)
        activeLayerID = copy.id
        endEdit()
    }

    func rasterizeActiveSmartObject() {
        guard canRasterizeSmartObject, let index = document?.layers.firstIndex(where: { $0.id == activeLayerID }) else { return }
        beginEdit("Rasterize Smart Object")
        document?.layers[index].smartObjectID = nil
        document?.pruneUnusedSmartObjects()
        endEdit()
    }

    /// Testable core of Replace Contents. Every instance receives the same immutable asset while its existing
    /// document-space rectangle remains the container, regardless of the replacement image's pixel dimensions.
    func replaceSmartObjectContents(with asset: ImportedImage) {
        guard canReplaceSmartObjectContents, let contentID = activeLayer?.smartObjectID,
              document?.smartObjects[contentID] != nil else { return }
        beginEdit("Replace Smart Object Contents")
        document?.smartObjects[contentID] = SmartObjectContent(id: contentID, asset: asset)
        for index in document?.layers.indices ?? 0..<0 where document?.layers[index].smartObjectID == contentID {
            document?.layers[index].asset = asset
            document?.layers[index].shape = nil
        }
        endEdit()
        brushRevision += 1
    }

    func replaceActiveSmartObjectContents(from url: URL) async {
        guard canReplaceSmartObjectContents, let contentID = activeLayer?.smartObjectID else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        isProjectBusy = true
        do {
            guard url.isFileURL, let document else { throw ImageImportError.unsupported }
            let remaining = 100_000_000 - document.sourcePixelCount(excludingSmartObject: contentID)
            let asset = try await ImageImporter.shared.decode(url, remainingPixels: remaining)
            isProjectBusy = false
            guard activeLayer?.smartObjectID == contentID else { return }
            replaceSmartObjectContents(with: asset)
        } catch {
            isProjectBusy = false
            importError = error.localizedDescription
        }
    }
}
