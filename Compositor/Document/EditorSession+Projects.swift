import Foundation

extension EditorSession {
    func projectSnapshot() -> ProjectSnapshot? {
        guard let document else { return nil }
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        let layers = document.layers.map { layer in
            if let asset = layer.asset { images[layer.id] = asset }
            if let mask = layer.mask { masks[layer.id] = mask.asset }
            return ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: layer.transform, imageFile: layer.asset == nil || layer.smartObjectID != nil ? nil : "\(layer.id.uuidString).png", parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png", maskEnabled: layer.mask?.isEnabled, maskSourceID: layer.maskSourceID, smartObjectID: layer.smartObjectID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement, maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style)
        }
        let used = Set(layers.compactMap(\.smartObjectID))
        let smartObjects = document.smartObjects.filter { used.contains($0.key) }.mapValues(\.asset)
        let records = smartObjects.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            smartObjects[id].map { ProjectSmartObjectRecord(id: id, name: $0.name, imageFile: "\(id.uuidString).png") }
        }
        var manifest = ProjectManifest(resolution: document.resolution, documentID: document.id, width: document.width,
            height: document.height, activeLayerID: activeLayerID, layers: layers)
        manifest.smartObjects = records.isEmpty ? nil : records
        return ProjectSnapshot(manifest: manifest, images: images, masks: masks, smartObjects: smartObjects)
    }

    /// Called only after the entire package has successfully validated and loaded.
    func installProject(_ snapshot: ProjectSnapshot, from url: URL) {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        let manifest = snapshot.manifest
        let smartObjects = Dictionary(uniqueKeysWithValues: snapshot.smartObjects.map {
            ($0.key, SmartObjectContent(id: $0.key, asset: $0.value))
        })
        transformEdit = nil
        document = CanvasDocument(id: manifest.documentID, width: manifest.width, height: manifest.height,
            layers: manifest.layers.map {
                ImageLayer(id: $0.id, asset: snapshot.images[$0.id], name: $0.name,
                           isVisible: $0.isVisible, transform: $0.transform, parentID: $0.parentID, isGroup: $0.isGroup == true, opacity: $0.opacity ?? 1, blendMode: $0.blendMode ?? .normal, mask: snapshot.mask(for: $0), maskSourceID: $0.maskSourceID, smartObjectID: $0.smartObjectID, adjustment: $0.adjustment,
                           shape: LayerShape.loaded($0.shape, image: snapshot.images[$0.id]?.image))
            }, smartObjects: smartObjects, resolution: manifest.resolution ?? 72)
        activeLayerID = manifest.activeLayerID
        projectURL = url
        renamingLayerID = nil
        history.reset()
        viewport.fit(documentSize: document!.size)
    }

    func clearProject() {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        transformEdit = nil
        document = nil
        activeLayerID = nil
        renamingLayerID = nil
        projectURL = nil
        history.reset()
    }

    func createNewProject(width: Int, height: Int) {
        guard !isProjectBusy, !isImporting, (1...30_000).contains(width), (1...30_000).contains(height) else { return }
        clearProject()
        createDocument(width: width, height: height, emptyLayer: true)
    }
}
