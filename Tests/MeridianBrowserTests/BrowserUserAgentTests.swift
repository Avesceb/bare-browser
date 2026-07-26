@testable import MeridianCore
import WebKit
import XCTest

@MainActor
final class BrowserUserAgentTests: XCTestCase {
    func testDesktopSafariCompatibleUserAgentUsesDesktopSafariTokens() {
        let userAgent = BrowserUserAgent.desktopSafariCompatible
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersion
        let expectedSafariVersion = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"

        XCTAssertTrue(userAgent.hasPrefix("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"))
        XCTAssertTrue(userAgent.contains("AppleWebKit/605.1.15"))
        XCTAssertTrue(userAgent.contains("Version/\(expectedSafariVersion)"))
        XCTAssertTrue(userAgent.hasSuffix("Safari/605.1.15"))
        XCTAssertFalse(userAgent.contains("Lumen Browser"))
        XCTAssertFalse(userAgent.contains("MeridianBrowser"))
    }

    func testApplyDesktopSafariCompatibilitySetsCustomUserAgent() {
        let webView = WKWebView()

        BrowserUserAgent.applyDesktopSafariCompatibility(to: webView)

        XCTAssertEqual(webView.customUserAgent, BrowserUserAgent.desktopSafariCompatible)
    }
}
