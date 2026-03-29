import SwiftUI
import AppKit
import Foundation

/// Check if `--test-bridge` was passed on the command line.
/// When true, the app runs a headless ping round-trip and exits.
private let isTestBridgeMode = CommandLine.arguments.contains("--test-bridge")

/// Check if `--test-analyze` was passed on the command line.
/// When true, the app runs a headless analyze round-trip and exits.
private let isTestAnalyzeMode = CommandLine.arguments.contains("--test-analyze")

@main
struct SilenceCutterApp: App {
    init() {
        // Swift Package executables default to accessory activation policy,
        // which prevents the app from appearing in the Dock and receiving focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            if isTestBridgeMode {
                BridgeTestRunner()
            } else if isTestAnalyzeMode {
                AnalyzeTestRunner()
            } else {
                ContentView()
            }
        }
        .defaultSize(width: 1200, height: 800)
    }
}

// MARK: - Bridge Test Runner

/// Headless view that runs the bridge ping test and exits the process.
private struct BridgeTestRunner: View {
    @State private var bridge = PythonBridge()

    var body: some View {
        Text("Running bridge test…")
            .task {
                await runBridgeTest()
            }
    }

    private func runBridgeTest() async {
        // Find the project root by walking up from cwd looking for silence_cutter/.
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        var projectRoot = dir.path
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("silence_cutter").path
            if fm.fileExists(atPath: candidate) {
                projectRoot = dir.path
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        print("[test-bridge] project root: \(projectRoot)")

        bridge.projectRoot = projectRoot

        do {
            try bridge.start()
            print("[test-bridge] Python process started")

            let result = try await bridge.call("ping", timeout: 10)
            if case .string(let value) = result, value == "pong" {
                print("[test-bridge] ✅ ping → pong round-trip OK")
            } else {
                print("[test-bridge] ❌ unexpected result: \(result)")
            }

            // Test echo
            let echoResult = try await bridge.call("echo", params: ["msg": "hello"], timeout: 10)
            print("[test-bridge] ✅ echo → \(echoResult)")

            bridge.stop()
            print("[test-bridge] Python process stopped")
            exit(0)
        } catch {
            print("[test-bridge] ❌ error: \(error)")
            bridge.stop()
            exit(1)
        }
    }
}

// MARK: - Analyze Test Runner

/// Headless view that runs the full analyze pipeline on a video file and exits.
/// Usage: SilenceCutterApp --test-analyze /path/to/video.mp4
private struct AnalyzeTestRunner: View {
    @State private var service = AnalysisService()

    var body: some View {
        Text("Running analyze test…")
            .task {
                await runAnalyzeTest()
            }
    }

    private func runAnalyzeTest() async {
        // Find the video path argument following --test-analyze
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: "--test-analyze"),
              flagIndex + 1 < args.count else {
            print("[test-analyze] ❌ Usage: --test-analyze <video_path>")
            exit(1)
        }

        let videoPath = args[flagIndex + 1]
        let videoURL = URL(fileURLWithPath: videoPath)

        guard FileManager.default.fileExists(atPath: videoPath) else {
            print("[test-analyze] ❌ File not found: \(videoPath)")
            exit(1)
        }

        print("[test-analyze] Analyzing: \(videoPath)")
        await service.analyze(videoURL: videoURL)

        if let error = service.error {
            print("[test-analyze] ❌ Analysis error: \(error)")
            exit(1)
        }

        print("[test-analyze] ✅ Analysis complete: \(service.segments.count) segments")
        if let first = service.segments.first {
            print("[test-analyze] First segment: [\(String(format: "%.1f", first.start))–\(String(format: "%.1f", first.end))] \(first.text)")
        }
        if let info = service.videoInfo {
            print("[test-analyze] Video info: \(info.width)x\(info.height) @ \(String(format: "%.1f", info.fps))fps, duration: \(String(format: "%.1f", info.duration))s")
        }
        exit(0)
    }
}
