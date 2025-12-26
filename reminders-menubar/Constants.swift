import Foundation

enum AppConstants {
    static let currentVersion: String = {
        guard let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
            return "-"
        }

        return "v\(bundleVersion) (build: \(buildVersion))"
    }()
    
    static let appName = "Reminders MenuBar"
    static let mainBundleId = "com.jc1.tech.bob"
    static let launcherBundleId = "com.jc1.tech"

    // Toggle native macOS Reminders integration. When false the app avoids
    // hitting CalendarAgent (EventKit) and operates in Firebase-only mode.
    static let useNativeReminders = true
}

enum GithubConstants {
    static let repository = "DamascenoRafael/reminders-menubar"
    static let repositoryPage = "https://github.com/\(repository)"
    static let latestReleasePage = "\(repositoryPage)/releases/latest"
}

enum ApiGithubConstants {
    static let latestRelease = "https://api.github.com/repos/\(GithubConstants.repository)/releases/latest"
}
