import Foundation

/// Manages the bundled Python environment for standalone distribution.
///
/// On first launch, creates a venv in ~/Library/Application Support/Silenci/
/// and installs the required Python packages. The `silence_cutter` module is
/// located inside the app bundle's Resources directory.
///
/// Subsequent launches reuse the existing venv (unless the version stamp differs).
@MainActor
@Observable
final class PythonEnvironment {

    // MARK: - State

    enum SetupState: Equatable, Sendable {
        case notStarted
        case checking
        case installing(detail: String)
        case ready(pythonPath: String, modulePath: String)
        case failed(message: String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    private(set) var state: SetupState = .notStarted

    /// Overall progress 0.0 – 1.0 during installation.
    private(set) var progress: Double = 0.0

    // MARK: - Constants

    /// Version stamp — bump this when dependencies change to force reinstall.
    private static let envVersion = "2"

    /// pip packages required for the server mode.
    /// Deliberately excludes gradio, librosa (unused by server.py).
    private static let serverDependencies: [String] = [
        "numpy<2",
        "soundfile>=0.12.0",
        "torch>=2.0.0",
        "silero-vad>=5.1.2",
        "mlx-audio>=0.3.0",
        "soynlp",
    ]

    // MARK: - Paths

    /// ~/Library/Application Support/Silenci/
    private var supportDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Silenci")
    }

    /// ~/Library/Application Support/Silenci/venv/
    private var venvDir: URL {
        supportDir.appendingPathComponent("venv")
    }

    /// ~/Library/Application Support/Silenci/venv/bin/python
    private var venvPython: URL {
        venvDir.appendingPathComponent("bin/python")
    }

    /// Version stamp file inside the venv.
    private var versionFile: URL {
        venvDir.appendingPathComponent(".sc-version")
    }

    /// Path to the bundled `silence_cutter` module.
    /// In development (swift run), falls back to walking up from cwd.
    private var modulePath: String {
        // 1. Check app bundle Resources
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = (resourcePath as NSString).appendingPathComponent("silence_cutter")
            if FileManager.default.fileExists(atPath: bundled) {
                return resourcePath
            }
        }

        // 2. Development fallback — walk up from cwd
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("silence_cutter").path
            if fm.fileExists(atPath: candidate) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
        }

        return FileManager.default.currentDirectoryPath
    }

    // MARK: - Setup

    /// Ensure the Python environment is ready. Idempotent — safe to call multiple times.
    func ensureReady() async {
        guard case .notStarted = state else { return }
        state = .checking
        progress = 0.0

        do {
            let pythonPath = try await setupVenv()
            let modPath = modulePath
            state = .ready(pythonPath: pythonPath, modulePath: modPath)
            progress = 1.0
            print("[PythonEnvironment] ✅ Ready — python: \(pythonPath), module: \(modPath)")
        } catch {
            state = .failed(message: error.localizedDescription)
            print("[PythonEnvironment] ❌ Setup failed: \(error)")
        }
    }

    /// Retry after a failure.
    func retry() async {
        state = .notStarted
        await ensureReady()
    }

    // MARK: - Cleanup

    /// Size of the installed venv on disk, in bytes. Returns 0 if not installed.
    var installedSize: Int64 {
        guard FileManager.default.fileExists(atPath: venvDir.path) else { return 0 }
        return Self.directorySize(url: venvDir)
    }

    /// Human-readable size string (e.g. "1.4 GB").
    var installedSizeString: String {
        let bytes = installedSize
        guard bytes > 0 else { return "Not installed" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Whether a venv is currently installed.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: venvPython.path)
    }

    /// Delete the entire Application Support directory (venv + any cached data).
    /// After calling this, the app will need to reinstall on next launch.
    func removeEnvironment() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: supportDir.path) {
            try fm.removeItem(at: supportDir)
        }
        state = .notStarted
        progress = 0.0
        print("[PythonEnvironment] 🗑️ Environment removed: \(supportDir.path)")
    }

    /// Path to the support directory, exposed for UI display.
    var supportDirPath: String {
        supportDir.path
    }

    /// Calculate total size of a directory recursively.
    private static func directorySize(url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Internal

    private func setupVenv() async throws -> String {
        let fm = FileManager.default

        // Ensure support directory exists
        try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)

        // Check if venv already exists with correct version
        if fm.fileExists(atPath: venvPython.path),
           let stamp = try? String(contentsOf: versionFile, encoding: .utf8),
           stamp.trimmingCharacters(in: .whitespacesAndNewlines) == Self.envVersion {
            print("[PythonEnvironment] Existing venv is up-to-date (v\(Self.envVersion))")
            progress = 1.0
            return venvPython.path
        }

        // Find system python3
        let systemPython = findSystemPython()
        print("[PythonEnvironment] Using system Python: \(systemPython)")

        // Create venv (or recreate if version mismatch)
        if fm.fileExists(atPath: venvDir.path) {
            state = .installing(detail: "Cleaning up existing environment…")
            try fm.removeItem(at: venvDir)
        }

        state = .installing(detail: "Python 가상환경 생성 중…")
        progress = 0.05
        try await run(systemPython, arguments: ["-m", "venv", venvDir.path])

        // Install dependencies
        let pipPath = venvDir.appendingPathComponent("bin/pip").path
        let totalDeps = Self.serverDependencies.count

        for (index, dep) in Self.serverDependencies.enumerated() {
            let pct = Double(index) / Double(totalDeps)
            progress = 0.1 + pct * 0.85
            state = .installing(detail: "\(dep) 설치 중… (\(index + 1)/\(totalDeps))")
            print("[PythonEnvironment] Installing \(dep) (\(index + 1)/\(totalDeps))")
            try await run(pipPath, arguments: ["install", dep])
        }

        // Write version stamp
        progress = 0.98
        state = .installing(detail: "Finishing environment setup…")
        try Self.envVersion.write(to: versionFile, atomically: true, encoding: .utf8)

        return venvPython.path
    }

    /// Find a usable system python3 — prefers Homebrew, then Xcode CLT, then PATH.
    private func findSystemPython() -> String {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "python3" // fall back to PATH lookup
    }

    /// Run a subprocess and wait for it to complete. Throws on non-zero exit.
    private func run(_ executable: String, arguments: [String]) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = stdoutPipe

        try proc.run()

        // Wait for termination on a background thread to avoid blocking MainActor.
        let (status, errorOutput) = await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? ""
                continuation.resume(returning: (proc.terminationStatus, errorMsg))
            }
        }

        if status != 0 {
            throw PythonEnvError.commandFailed(
                command: "\(executable) \(arguments.joined(separator: " "))",
                message: errorOutput
            )
        }
    }
}

// MARK: - Errors

enum PythonEnvError: Error, LocalizedError {
    case commandFailed(command: String, message: String)
    case pythonNotFound

    var errorDescription: String? {
        switch self {
        case .commandFailed(let cmd, let msg):
            "Command failed: \(cmd)\n\(msg)"
        case .pythonNotFound:
            "Python 3을 찾을 수 없습니다. python3을 먼저 설치해주세요."
        }
    }
}
