import Foundation

/// Device data stays local. Old AliceBattery installations retain their calibration.
enum AppStorage {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mac-akko", isDirectory: true)
    static func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    static func migrateLegacy() {
        let manager = FileManager.default
        let legacy = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AliceBattery", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["full-reference.json", "voltage-history.json"] {
                let source = legacy.appendingPathComponent(name), destination = file(name)
                if !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: source.path) {
                    try manager.copyItem(at: source, to: destination)
                }
            }
        } catch { NSLog("Local calibration migration failed: %@", error.localizedDescription) }
    }
}
