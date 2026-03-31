import Foundation

/// Localization helper — finds the resource bundle manually to avoid SwiftPM Bundle.module crashes
/// when the app is distributed as a standalone .app bundle.
enum L10n {
    /// Supported app languages.
    enum AppLanguage: String, CaseIterable, Identifiable {
        case system = "system"
        case ko = "ko"
        case en = "en"
        case ja = "ja"
        case zhHans = "zh-Hans"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "시스템 기본"
            case .ko: return "한국어"
            case .en: return "English"
            case .ja: return "日本語"
            case .zhHans: return "中文"
            }
        }
    }

    /// Current app language override. "system" means follow system locale.
    static var currentLanguage: AppLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: "sc_appLanguage") ?? "system"
            return AppLanguage(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "sc_appLanguage")
            // Invalidate cached bundle
            _overrideBundle = nil
        }
    }

    /// The resource bundle containing Localizable.strings.
    private static let baseBundle: Bundle = {
        let bundleName = "SilenciApp_SilenciApp"

        // 1. Next to the executable (Contents/MacOS/)
        let executableURL = Bundle.main.bundleURL
        if let b = Bundle(url: executableURL.appendingPathComponent("\(bundleName).bundle")) {
            return b
        }

        // 2. In Resources (Contents/Resources/)
        if let resourceURL = Bundle.main.resourceURL,
           let b = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle")) {
            return b
        }

        // 3. In the app bundle root
        if let b = Bundle(url: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(bundleName).bundle")) {
            return b
        }

        // 4. Two levels up from executable (Contents/MacOS/../../Resources/)
        let twoUp = executableURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(bundleName).bundle")
        if let b = Bundle(path: twoUp.path) {
            return b
        }

        // 5. Fallback: use main bundle
        print("[L10n] ⚠️ Resource bundle not found — falling back to Bundle.main")
        return Bundle.main
    }()

    /// Cached language-specific bundle.
    nonisolated(unsafe) private static var _overrideBundle: Bundle?

    /// The effective bundle for the current language setting.
    private static var bundle: Bundle {
        if let cached = _overrideBundle { return cached }

        let lang = currentLanguage
        if lang == .system {
            _overrideBundle = baseBundle
            return baseBundle
        }

        // Find the .lproj for the specified language
        if let path = baseBundle.path(forResource: lang.rawValue, ofType: "lproj"),
           let b = Bundle(path: path) {
            _overrideBundle = b
            return b
        }

        // Fallback
        _overrideBundle = baseBundle
        return baseBundle
    }

    static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: bundle, comment: "")
        return String(format: format, arguments: args)
    }
}
