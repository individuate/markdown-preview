import WebKit
import XCTest
@testable import MarkdownHelpers

final class QuickLookLinkNavigationTests: XCTestCase {
    @MainActor
    func testRenderedClicksReachQuickLookExternalOpener() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ql-links-\(UUID().uuidString).md")
        try """
        [Custom](unlisted-app://open/item)

        [Web](https://example.com)

        [Unsafe](javascript:alert(1))
        """.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = PreviewViewController()
        var opened: [URL] = []
        controller.openExternalLink = { url, _ in opened.append(url) }
        try await controller.preparePreviewOfFile(at: file)
        let view = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        defer { view.stopLoading() }
        let deadline = Date().addingTimeInterval(15)
        while view.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(view.isLoading)
        for (index, destination) in ["unlisted-app://open/item", "https://example.com/"].enumerated() {
            _ = try await view.evaluateJavaScript("document.querySelectorAll('article a')[\(index)].click(); true")
            let clickDeadline = Date().addingTimeInterval(3)
            while opened.count <= index && Date() < clickDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(opened.last?.absoluteString, destination)
            XCTAssertEqual(opened.count, index + 1)
            XCTAssertEqual(view.url?.absoluteString, "about:blank", "External links must not navigate the preview")
        }
        let unsafeHref = try await view.evaluateJavaScript("document.querySelectorAll('article a')[2].hasAttribute('href')")
        XCTAssertEqual(unsafeHref as? Bool, false)
    }

    @MainActor
    func testHeadingLinksScrollToGitHubStyleSlugs() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ql-headings-\(UUID().uuidString).md")
        let filler = String(repeating: "Filler paragraph.\n\n", count: 200)
        try """
        [Bottom](#bottom-of-this-document) [Repeat](#repeat-1) [Missing](#no-such-heading)

        \(filler)

        ## Repeat

        \(filler)

        ## Repeat

        \(filler)

        ## Bottom of this document

        \(filler)
        """.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = PreviewViewController()
        var opened: [URL] = []
        controller.openExternalLink = { url, _ in opened.append(url) }
        try await controller.preparePreviewOfFile(at: file)
        let view = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        defer { view.stopLoading() }
        let deadline = Date().addingTimeInterval(15)
        while view.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(view.isLoading)

        func click(_ index: Int, landsOn headingIndex: Int?) async throws {
            _ = try await view.evaluateJavaScript("window.scrollTo(0, 0); document.querySelectorAll('article a')[\(index)].click(); true")
            guard let headingIndex else {
                try await Task.sleep(for: .milliseconds(300))
                let scrollY = try await view.evaluateJavaScript("window.scrollY") as? Double
                XCTAssertEqual(scrollY, 0, "An unknown fragment must not scroll")
                return
            }
            let script = "Math.round(document.querySelectorAll('article h2')[\(headingIndex)].getBoundingClientRect().top)"
            let clickDeadline = Date().addingTimeInterval(3)
            var top = try await view.evaluateJavaScript(script) as? Double
            while (top ?? .infinity) > 1, Date() < clickDeadline {
                try await Task.sleep(for: .milliseconds(20))
                top = try await view.evaluateJavaScript(script) as? Double
            }
            XCTAssertEqual(top ?? .infinity, 0, accuracy: 1, "Link \(index) should scroll heading \(headingIndex) to the top")
        }
        try await click(0, landsOn: 2)
        try await click(1, landsOn: 1)
        try await click(2, landsOn: nil)
        XCTAssertTrue(opened.isEmpty, "Fragment links must stay in the preview, got \(opened)")
        XCTAssertEqual(view.url?.absoluteString, "about:blank")
    }

    func testPageFragmentAcceptsPlainAndEncodedHash() throws {
        XCTAssertEqual(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "about:blank#intro"))), "intro")
        XCTAssertEqual(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "about:blank%23intro"))), "intro")
        XCTAssertEqual(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "about:blank#caf%C3%A9"))), "café")
        XCTAssertNil(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "about:blank#"))))
        XCTAssertNil(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "about:srcdoc#intro"))))
        XCTAssertNil(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "https://example.com/#intro"))))
    }
}
