import Foundation

enum AppConstants {
    static let issuesURL = URL(string: "https://github.com/Tesseric/careless-whisper/issues/new/choose")!
    static let repoURL = URL(string: "https://github.com/Tesseric/careless-whisper")!
}

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
