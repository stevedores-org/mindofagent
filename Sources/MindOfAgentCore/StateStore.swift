import Foundation

/// Serialises reads and writes of `AppState` to a JSON file on disk. Backed
/// by an actor for thread-safety; safe to share across the app.
///
/// `save(_:)` uses `Data.write(to:options:[.atomic])` which on Darwin renames
/// from a temp file. That protects against a *process* kill mid-write — the
/// rename is atomic at the filesystem layer, so partial writes never become
/// visible. It does **not** guarantee durability against a system crash or
/// power loss in the seconds after `save` returns: the rename's metadata is
/// still in the page cache and a kernel panic in that window can lose it.
/// For full power-loss safety you'd need `fsync` on the temp file plus
/// `fsync` on the parent directory — out of scope for a small JSON state
/// file.
///
/// A file that exists but fails to decode (corrupt JSON, schema drift) is
/// **moved aside** to `state.json.corrupt-<unix-timestamp>` and replaced
/// with defaults — we never crash the app on disk gore, and the original
/// bytes survive for postmortem / bug-report attachment.
///
/// No file lock: two concurrent processes pointed at the same `fileURL`
/// will see last-writer-wins (the `.atomic` write means no torn writes,
/// but writes are not serialised across processes). In practice
/// MindOfAgent is a menu-bar app and users won't double-launch it; if
/// that changes, switch to an advisory `flock`/`fcntl` strategy.
public actor StateStore {
    /// Immutable for the lifetime of the store, so safe to read from any
    /// isolation context.
    public nonisolated let fileURL: URL
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
            // Preserve the original bytes so a future schema-drift bug or a
            // user bug report has something to inspect. Naming includes a
            // unix timestamp so repeated corruption events don't overwrite
            // each other.
            let backup = fileURL.appendingPathExtension(
                "corrupt-\(Int(Date().timeIntervalSince1970))"
            )
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            FileHandle.standardError.write(Data(
                "StateStore: corrupt state.json at \(fileURL.path) — moved to \(backup.lastPathComponent), replacing with defaults (\(error))\n"
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
