import Foundation

/// Serialises reads and writes of `AppState` to a JSON file on disk. Backed
/// by an actor for thread-safety; safe to share across the app.
///
/// `save(_:)` uses `Data.write(to:options:[.atomic])` which on Darwin renames
/// from a temp file — so a process killed mid-write keeps the previously
/// committed contents.
///
/// A file that exists but fails to decode (corrupt JSON, schema drift) is
/// logged to stderr and replaced with defaults — we never crash the app on
/// disk gore.
public actor StateStore {
    public let fileURL: URL
    private var cached: AppState?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/MindOfAgent/state.json`.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let appSupport: URL
        if let url = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            appSupport = url
        } else {
            appSupport = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        }
        return appSupport
            .appendingPathComponent("MindOfAgent", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    public func load() -> AppState {
        if let cached { return cached }

        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            let defaults = AppState()
            try? writeAtomically(defaults)
            cached = defaults
            return defaults
        }

        do {
            let state = try JSONDecoder().decode(AppState.self, from: data)
            cached = state
            return state
        } catch {
            FileHandle.standardError.write(Data(
                "StateStore: corrupt state.json at \(fileURL.path) — replacing with defaults (\(error))\n"
                    .utf8
            ))
            let defaults = AppState()
            try? writeAtomically(defaults)
            cached = defaults
            return defaults
        }
    }

    public func save(_ state: AppState) throws {
        try writeAtomically(state)
        cached = state
    }

    public func update(_ transform: (inout AppState) -> Void) throws -> AppState {
        var state = load()
        transform(&state)
        try writeAtomically(state)
        cached = state
        return state
    }

    private func writeAtomically(_ state: AppState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)

        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }
}
