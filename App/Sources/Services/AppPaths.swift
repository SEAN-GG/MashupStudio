import Foundation

enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var projectsDir: URL {
        ensure(documents.appendingPathComponent("Projects", isDirectory: true))
    }

    static var assetsDir: URL {
        ensure(documents.appendingPathComponent("AssetLibrary", isDirectory: true))
    }

    static var exportsDir: URL {
        ensure(documents.appendingPathComponent("Exports", isDirectory: true))
    }

    static func projectFile(_ id: UUID) -> URL {
        projectsDir.appendingPathComponent("\(id.uuidString).json")
    }

    static func assetFolder(_ id: UUID) -> URL {
        ensure(assetsDir.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    static func assetAudioFile(_ asset: AudioAsset) -> URL {
        assetFolder(asset.id).appendingPathComponent(asset.fileName)
    }

    static func assetPeaksFile(_ id: UUID) -> URL {
        assetFolder(id).appendingPathComponent("peaks.bin")
    }

    static func assetStemsFolder(_ id: UUID) -> URL {
        ensure(assetFolder(id).appendingPathComponent("stems", isDirectory: true))
    }

    static func stemFile(assetID: UUID, kind: StemKind) -> URL {
        assetStemsFolder(assetID).appendingPathComponent("\(kind.rawValue).m4a")
    }

    static var assetIndexFile: URL {
        assetsDir.appendingPathComponent("assets.json")
    }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
