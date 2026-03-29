import Foundation

// MARK: - JSON-RPC types

/// A JSON-RPC 2.0 request sent to the Python subprocess.
private struct RPCRequest: Encodable {
    let id: Int
    let method: String
    let params: [String: AnyCodableValue]
}

/// A JSON-RPC 2.0 response received from the Python subprocess.
private struct RPCResponse: Decodable {
    let id: Int?
    let result: AnyCodableValue?
    let error: RPCError?
    let method: String?
    let params: AnyCodableValue?
}

/// A JSON-RPC error object.
struct RPCError: Decodable, Error, Sendable, CustomStringConvertible {
    let code: Int
    let message: String
    let data: AnyCodableValue?

    var description: String { "RPCError(\(code)): \(message)" }
}

/// Progress info emitted by the Python server via JSON-RPC notifications.
struct ProgressInfo: Sendable {
    let phase: String
    let percent: Int
    let detail: String
}

/// Errors specific to PythonBridge operation.
enum BridgeError: Error, CustomStringConvertible {
    case processNotRunning
    case noStdin
    case timeout
    case unexpectedResponse(String)
    case decodingFailed(String)
    case pythonError(RPCError)

    var description: String {
        switch self {
        case .processNotRunning: "Python process is not running"
        case .noStdin: "No stdin pipe available"
        case .timeout: "Request timed out"
        case .unexpectedResponse(let msg): "Unexpected response: \(msg)"
        case .decodingFailed(let msg): "Decoding failed: \(msg)"
        case .pythonError(let err): "Python error: \(err)"
        }
    }
}


// MARK: - AnyCodableValue — type-erased JSON value for Codable round-tripping

/// A type-erased JSON value that supports both Codable directions.
/// Used for JSON-RPC `params` (encode) and `result`/`error.data` (decode).
enum AnyCodableValue: Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    // MARK: Decodable
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: AnyCodableValue].self) {
            self = .object(obj)
        } else {
            self = .null
        }
    }

    // MARK: Encodable
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    /// Attempt to decode this value as a concrete Decodable type.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

extension AnyCodableValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}
extension AnyCodableValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .int(value) }
}
extension AnyCodableValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .double(value) }
}
extension AnyCodableValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}


// MARK: - PythonBridge

/// Manages a Python subprocess running `silence_cutter.server` and provides
/// async JSON-RPC communication over stdin/stdout pipes.
///
/// Usage:
/// ```swift
/// let bridge = PythonBridge()
/// try await bridge.start()
/// let result = try await bridge.call("ping")
/// ```
@MainActor
@Observable
final class PythonBridge {

    // MARK: Published state

    /// Current progress info from the Python server (updated on main actor).
    private(set) var currentProgress: ProgressInfo?

    /// Whether the Python process is currently running.
    private(set) var isRunning = false

    /// Last error message for diagnostics.
    private(set) var lastError: String?

    // MARK: Internal state

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Auto-incrementing request ID.
    private var nextRequestId = 1

    /// Pending requests awaiting a response, keyed by request id.
    /// Each continuation is resumed exactly once when the matching response arrives.
    private var pendingRequests: [Int: CheckedContinuation<AnyCodableValue, any Error>] = [:]

    /// Background task that reads stdout lines.
    private var readTask: Task<Void, Never>?

    /// Path to the Python interpreter. Defaults to system `python3`.
    /// Overridden at start() to prefer .venv/bin/python if available.
    var pythonPath: String = "/usr/bin/python3"

    /// Path to the project root (parent of `silence_cutter/`).
    /// Defaults to the bundle's resource path or current directory.
    var projectRoot: String = "."

    // MARK: Lifecycle

    /// Start the Python JSON-RPC subprocess.
    func start() throws {
        guard !isRunning else { return }

        // Prefer .venv/bin/python in projectRoot if it exists.
        let venvPython = (projectRoot as NSString).appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            pythonPath = venvPython
        }

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-m", "silence_cutter.server"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Handle unexpected termination.
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTermination()
            }
        }

        try proc.run()

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.isRunning = true
        self.lastError = nil
        self.pendingRequests = [:]

        // Start reading stdout in background.
        readTask = Task { [weak self] in
            await self?.readLoop(handle: stdout.fileHandleForReading)
        }
    }

    /// Stop the Python subprocess gracefully.
    func stop() {
        readTask?.cancel()
        readTask = nil

        // Close stdin to signal EOF — the Python server exits on EOF.
        try? stdinPipe?.fileHandleForWriting.close()

        if let proc = process, proc.isRunning {
            proc.terminate()
        }

        // Fail any pending requests.
        let pending = pendingRequests
        pendingRequests = [:]
        for (_, continuation) in pending {
            continuation.resume(throwing: BridgeError.processNotRunning)
        }

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        isRunning = false
    }

    deinit {
        // Best-effort cleanup — stop() must be called from MainActor before dealloc
        // for a clean shutdown. This handles the fallback case.
    }

    // MARK: JSON-RPC calls

    /// Send a JSON-RPC request and await the response.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method name (e.g. "ping", "analyze").
    ///   - params: Key-value parameters. Default is empty.
    ///   - timeout: Seconds to wait before timing out. Default is 300 (5 min).
    /// - Returns: The `result` field of the JSON-RPC response.
    func call(
        _ method: String,
        params: [String: AnyCodableValue] = [:],
        timeout: TimeInterval = 300
    ) async throws -> AnyCodableValue {
        guard isRunning, let stdinHandle = stdinPipe?.fileHandleForWriting else {
            throw BridgeError.processNotRunning
        }

        let requestId = nextRequestId
        nextRequestId += 1

        let request = RPCRequest(id: requestId, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        // Append newline — the protocol is newline-delimited.
        var lineData = data
        lineData.append(contentsOf: [0x0A]) // '\n'

        // Write request to stdin.
        try stdinHandle.write(contentsOf: lineData)

        // Register continuation, then race response vs timeout.
        let result: AnyCodableValue = try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[requestId] = continuation

            // Timeout watchdog — fires on a detached task to avoid actor reentrancy issues.
            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expireRequest(id: requestId)
            }
        }
        return result
    }

    /// Convenience: call a method and decode the result as a specific type.
    func call<T: Decodable>(
        _ method: String,
        params: [String: AnyCodableValue] = [:],
        timeout: TimeInterval = 300,
        as type: T.Type
    ) async throws -> T {
        let raw = try await call(method, params: params, timeout: timeout)
        return try raw.decode(type)
    }

    // MARK: Stdout read loop

    /// Continuously reads newline-delimited JSON from the Python subprocess stdout.
    /// Dispatches responses to pending continuations and progress notifications to state.
    private func readLoop(handle: FileHandle) async {
        // Read data incrementally and split by newlines.
        var buffer = Data()

        while !Task.isCancelled {
            let chunk: Data
            do {
                chunk = try await readAvailable(from: handle)
            } catch {
                break // pipe closed or error
            }

            if chunk.isEmpty {
                break // EOF
            }

            buffer.append(chunk)

            // Process complete lines.
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                guard !lineData.isEmpty else { continue }

                do {
                    let response = try JSONDecoder().decode(RPCResponse.self, from: Data(lineData))
                    handleResponse(response)
                } catch {
                    // Non-JSON line (e.g. debug output) — skip.
                    continue
                }
            }
        }

        // On loop exit, fail any remaining pending requests.
        cleanupPending()
    }

    /// Read available data from a FileHandle asynchronously.
    /// Returns empty Data on EOF.
    nonisolated private func readAvailable(from handle: FileHandle) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.availableData
                continuation.resume(returning: data)
            }
        }
    }

    /// Route a decoded response to the appropriate handler.
    @MainActor
    private func handleResponse(_ response: RPCResponse) {
        // Progress notification (no id, method == "progress").
        if response.id == nil, response.method == "progress" {
            if case .object(let obj) = response.params {
                let phase: String
                if case .string(let s) = obj["phase"] { phase = s } else { phase = "" }
                let percent: Int
                if case .int(let i) = obj["percent"] { percent = i } else { percent = 0 }
                let detail: String
                if case .string(let s) = obj["detail"] { detail = s } else { detail = "" }
                currentProgress = ProgressInfo(phase: phase, percent: percent, detail: detail)
            }
            return
        }

        // Response to a request (has id).
        guard let id = response.id else { return }
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }

        if let error = response.error {
            lastError = error.description
            continuation.resume(throwing: BridgeError.pythonError(error))
        } else {
            continuation.resume(returning: response.result ?? .null)
        }
    }

    /// Clean up pending requests on read loop termination.
    @MainActor
    private func cleanupPending() {
        let pending = pendingRequests
        pendingRequests = [:]
        for (_, continuation) in pending {
            continuation.resume(throwing: BridgeError.processNotRunning)
        }
    }

    /// Expire a request if it's still pending (timeout).
    @MainActor
    private func expireRequest(id: Int) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        lastError = "Request \(id) timed out"
        continuation.resume(throwing: BridgeError.timeout)
    }

    /// Handle subprocess termination.
    @MainActor
    private func handleTermination() {
        isRunning = false
        readTask?.cancel()
        readTask = nil

        let pending = pendingRequests
        pendingRequests = [:]
        for (_, continuation) in pending {
            continuation.resume(throwing: BridgeError.processNotRunning)
        }
    }
}
