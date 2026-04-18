import Foundation

/// Manages CRUD operations for custom pet sprites.
///
/// Storage:
/// - Metadata: `~/.snor-oh/custom-ohhs.json`
/// - Sprite files: `~/.snor-oh/custom-sprites/`
///
/// Main-thread only (mutates @Observable state).
@Observable
final class CustomOhhManager {

    private(set) var ohhs: [CustomOhhData] = []

    private let metadataFile: URL
    private let spritesDir: URL

    static let shared = CustomOhhManager()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(".snor-oh")
        metadataFile = base.appendingPathComponent("custom-ohhs.json")
        spritesDir = base.appendingPathComponent("custom-sprites")
    }

    // MARK: - Load

    func load() {
        ensureDirectories()
        guard FileManager.default.fileExists(atPath: metadataFile.path) else { return }
        do {
            let data = try Data(contentsOf: metadataFile)
            ohhs = try JSONDecoder().decode([CustomOhhData].self, from: data)
        } catch {
            print("[custom-ohhs] failed to load: \(error)")
        }
    }

    // MARK: - Create

    @discardableResult
    func addOhh(name: String, spriteFiles: [Status: (sourcePath: String, frames: Int)]) -> String? {
        for status in Status.allCases {
            guard spriteFiles[status] != nil else {
                print("[custom-ohhs] missing sprite for \(status.rawValue)")
                return nil
            }
        }

        let id = "custom-\(UUID().uuidString)"
        ensureDirectories()

        var written: [URL] = []
        var sprites: [String: CustomOhhData.SpriteEntry] = [:]

        for status in Status.allCases {
            let entry = spriteFiles[status]!
            let fileName = "\(id)-\(status.rawValue).png"
            let dest = spritesDir.appendingPathComponent(fileName)
            do {
                try FileManager.default.copyItem(
                    at: URL(fileURLWithPath: entry.sourcePath),
                    to: dest
                )
                written.append(dest)
            } catch {
                print("[custom-ohhs] copy failed for \(status.rawValue): \(error)")
                for url in written { try? FileManager.default.removeItem(at: url) }
                return nil
            }
            sprites[status.rawValue] = .init(fileName: fileName, frames: entry.frames)
        }

        let ohh = CustomOhhData(id: id, name: name, sprites: sprites)
        ohhs.append(ohh)
        persist()
        return id
    }

    @discardableResult
    func addOhhFromBlobs(
        name: String,
        spriteBlobs: [Status: (data: Data, frames: Int)],
        smartImportMeta: (sheetData: Data, frameInputs: [Status: String])? = nil
    ) -> String? {
        for status in Status.allCases {
            guard spriteBlobs[status] != nil else {
                print("[custom-ohhs] missing blob for \(status.rawValue)")
                return nil
            }
        }

        let id = "custom-\(UUID().uuidString)"
        ensureDirectories()

        var written: [URL] = []
        var sprites: [String: CustomOhhData.SpriteEntry] = [:]

        for status in Status.allCases {
            let entry = spriteBlobs[status]!
            let fileName = "\(id)-\(status.rawValue).png"
            let dest = spritesDir.appendingPathComponent(fileName)
            do {
                try entry.data.write(to: dest, options: .atomic)
                written.append(dest)
            } catch {
                print("[custom-ohhs] write failed for \(status.rawValue): \(error)")
                for url in written { try? FileManager.default.removeItem(at: url) }
                return nil
            }
            sprites[status.rawValue] = .init(fileName: fileName, frames: entry.frames)
        }

        var meta: CustomOhhData.SmartImportMeta?
        if let smartImportMeta {
            let sheetFileName = "\(id)-source.png"
            let sheetDest = spritesDir.appendingPathComponent(sheetFileName)
            do {
                try smartImportMeta.sheetData.write(to: sheetDest, options: .atomic)
            } catch {
                print("[custom-ohhs] write failed for source sheet: \(error)")
            }
            var inputs: [String: String] = [:]
            for (status, input) in smartImportMeta.frameInputs {
                inputs[status.rawValue] = input
            }
            meta = .init(sheetFileName: sheetFileName, frameInputs: inputs)
        }

        let ohh = CustomOhhData(id: id, name: name, sprites: sprites, smartImportMeta: meta)
        ohhs.append(ohh)
        persist()
        return id
    }

    // MARK: - Update

    func updateOhh(
        id: String,
        name: String,
        spriteFiles: [Status: (sourcePath: String?, frames: Int)]
    ) {
        guard let idx = ohhs.firstIndex(where: { $0.id == id }) else { return }
        let existing = ohhs[idx]
        ensureDirectories()

        var sprites: [String: CustomOhhData.SpriteEntry] = [:]
        for status in Status.allCases {
            if let entry = spriteFiles[status] {
                if let sourcePath = entry.sourcePath {
                    let fileName = "\(id)-\(status.rawValue).png"
                    let dest = spritesDir.appendingPathComponent(fileName)
                    let tmp = spritesDir.appendingPathComponent("\(fileName).tmp")
                    do {
                        try FileManager.default.copyItem(
                            at: URL(fileURLWithPath: sourcePath), to: tmp
                        )
                        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
                    } catch {
                        print("[custom-ohhs] copy failed for \(status.rawValue): \(error)")
                        try? FileManager.default.removeItem(at: tmp)
                    }
                    sprites[status.rawValue] = .init(fileName: fileName, frames: entry.frames)
                } else if let existingEntry = existing.sprite(for: status) {
                    sprites[status.rawValue] = .init(fileName: existingEntry.fileName, frames: entry.frames)
                }
            } else if let existingEntry = existing.sprite(for: status) {
                sprites[status.rawValue] = existingEntry
            }
        }

        ohhs[idx] = CustomOhhData(id: id, name: name, sprites: sprites,
                                  smartImportMeta: existing.smartImportMeta)
        SpriteCache.shared.purgeCustomPet(id)
        persist()
    }

    func updateOhhFromSmartImport(
        id: String,
        name: String,
        spriteBlobs: [Status: (data: Data, frames: Int)],
        sheetData: Data,
        frameInputs: [Status: String]
    ) {
        guard let idx = ohhs.firstIndex(where: { $0.id == id }) else { return }
        ensureDirectories()

        var written: [URL] = []
        var sprites: [String: CustomOhhData.SpriteEntry] = [:]
        for status in Status.allCases {
            guard let entry = spriteBlobs[status] else {
                print("[custom-ohhs] missing blob for \(status.rawValue)")
                for url in written { try? FileManager.default.removeItem(at: url) }
                return
            }
            let fileName = "\(id)-\(status.rawValue).png"
            let dest = spritesDir.appendingPathComponent(fileName)
            do {
                try entry.data.write(to: dest, options: .atomic)
                written.append(dest)
            } catch {
                print("[custom-ohhs] write failed for \(status.rawValue): \(error)")
                for url in written { try? FileManager.default.removeItem(at: url) }
                return
            }
            sprites[status.rawValue] = .init(fileName: fileName, frames: entry.frames)
        }

        let sheetFileName = "\(id)-source.png"
        let sheetDest = spritesDir.appendingPathComponent(sheetFileName)
        try? sheetData.write(to: sheetDest, options: .atomic)

        var inputs: [String: String] = [:]
        for (status, input) in frameInputs { inputs[status.rawValue] = input }

        ohhs[idx] = CustomOhhData(
            id: id, name: name, sprites: sprites,
            smartImportMeta: .init(sheetFileName: sheetFileName, frameInputs: inputs)
        )
        SpriteCache.shared.purgeCustomPet(id)
        persist()
    }

    // MARK: - Delete

    func deleteOhh(id: String) {
        guard let idx = ohhs.firstIndex(where: { $0.id == id }) else { return }
        let ohh = ohhs[idx]
        for (_, entry) in ohh.sprites {
            try? FileManager.default.removeItem(at: spritesDir.appendingPathComponent(entry.fileName))
        }
        if let sheetName = ohh.smartImportMeta?.sheetFileName {
            try? FileManager.default.removeItem(at: spritesDir.appendingPathComponent(sheetName))
        }
        ohhs.remove(at: idx)
        persist()
    }

    // MARK: - Lookup

    func ohh(withID id: String) -> CustomOhhData? {
        ohhs.first { $0.id == id }
    }

    func spritePath(fileName: String) -> URL {
        spritesDir.appendingPathComponent(fileName)
    }

    var allPetIDs: [String] {
        SpriteConfig.builtInPets + ohhs.map(\.id)
    }

    // MARK: - Private

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: spritesDir, withIntermediateDirectories: true)
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(ohhs)
            try data.write(to: metadataFile, options: .atomic)
        } catch {
            print("[custom-ohhs] failed to persist: \(error)")
        }
    }
}
