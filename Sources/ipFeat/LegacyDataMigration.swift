import Foundation

enum LegacyDataMigration {
    static let oldBundleIdentifier = "local.ipinformer.app"
    static let newBundleIdentifier = "local.ipfeat.app"
    static let oldSupportDirectory = "IPInformer"
    static let newSupportDirectory = "ipFeat"

    static func run() {
        copyPreferences()
        do { try copySupportFiles() }
        catch { NSLog("ipFeat could not copy prior support files: %@", error.localizedDescription) }
    }

    private static func copyPreferences() {
        guard let old = UserDefaults(suiteName: oldBundleIdentifier) else { return }
        let current = UserDefaults.standard
        let newValues = current.persistentDomain(forName: newBundleIdentifier) ?? [:]
        for key in ["routingConfiguration.v1", "mainConfigurationHistory.v1", "processAISettings",
                    "preferredAppLanguage", "AppleLanguages"] where newValues[key] == nil {
            if let value = old.object(forKey: key) { current.set(value, forKey: key) }
        }
    }

    private static func copySupportFiles() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let source = root.appendingPathComponent(oldSupportDirectory, isDirectory: true)
        let destination = root.appendingPathComponent(newSupportDirectory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try copyMissingContents(from: source, to: destination)
    }

    static func copyMissingContents(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            // A running previous version leaves a Unix prompt socket here.
            // Copy only persistent files and directories.
            guard values.isRegularFile == true || values.isDirectory == true else { continue }
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if values.isDirectory == true {
                guard !manager.fileExists(atPath: target.path) ||
                        (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                try copyMissingContents(from: item, to: target)
            } else if !manager.fileExists(atPath: target.path) {
                try manager.copyItem(at: item, to: target)
            }
        }
    }
}
