import Foundation
import WebKit

enum BrowserUserAgent {
    static var desktopSafariCompatible: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let safariVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
    }

    @MainActor
    static func applyDesktopSafariCompatibility(to webView: WKWebView) {
        webView.customUserAgent = desktopSafariCompatible
    }
}
