import Foundation

/// The running build, for the line under Settings' device id. Marketing version
/// and build number both come from the bundle, so they track `MARKETING_VERSION`
/// and `CURRENT_PROJECT_VERSION` in project.yml and can't drift from what was
/// actually shipped.
enum AppVersion {
    static var marketing: String {
        string(for: "CFBundleShortVersionString") ?? "—"
    }
    static var build: String {
        string(for: "CFBundleVersion") ?? "—"
    }

    /// "Version 1.0 (1)"
    static var display: String { "Version \(marketing) (\(build))" }

    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}
