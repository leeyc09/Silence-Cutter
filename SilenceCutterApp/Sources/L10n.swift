import Foundation

/// Localization helper — wraps `NSLocalizedString` with the correct bundle for SwiftPM resources.
enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: .module, comment: "")
        return String(format: format, arguments: args)
    }
}
