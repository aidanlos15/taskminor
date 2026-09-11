import XCTest
@testable import Availeth

final class HostNormalizerTests: XCTestCase {

    func testHostOfURL() {
        XCTAssertEqual(HostNormalizer.host(of: URL(string: "https://onlinebanking.aib.ie/inet/roi/login.htm?x=1")!), "onlinebanking.aib.ie")
        XCTAssertEqual(HostNormalizer.host(of: URL(string: "https://www.aib.ie/")!), "aib.ie")
        XCTAssertEqual(HostNormalizer.host(of: URL(string: "HTTP://Docs.Google.com./x")!), "docs.google.com")
        XCTAssertNil(HostNormalizer.host(of: URL(string: "chrome://settings/")!))
        XCTAssertNil(HostNormalizer.host(of: URL(string: "file:///Users/x/a.html")!))
        XCTAssertNil(HostNormalizer.host(of: URL(string: "http://localhost:3000/")!))
        XCTAssertNil(HostNormalizer.host(of: URL(string: "http://192.168.1.1/")!))
        XCTAssertNil(HostNormalizer.host(of: URL(string: "http://mac.local/")!))
        XCTAssertNil(HostNormalizer.host(of: URL(string: "http://intranet/")!), "single-label hosts have no public icon")
    }

    func testNormaliseBareHosts() {
        XCTAssertEqual(HostNormalizer.normalise("www.aib.ie/inet"), "aib.ie")
        XCTAssertEqual(HostNormalizer.normalise("m.facebook.com"), "facebook.com")
        XCTAssertEqual(HostNormalizer.normalise("user@host.example.com:8443"), "host.example.com")
        XCTAssertNil(HostNormalizer.normalise("aib"), "a half-typed address is not a host")
        XCTAssertNil(HostNormalizer.normalise("how to fix.swift"), "search text")
        XCTAssertNil(HostNormalizer.normalise("-bad-.com"))
    }

    func testRegistrableDomain() {
        XCTAssertEqual(HostNormalizer.registrableDomain("onlinebanking.aib.ie"), "aib.ie")
        XCTAssertEqual(HostNormalizer.registrableDomain("docs.google.com"), "google.com")
        XCTAssertEqual(HostNormalizer.registrableDomain("a.foo.co.uk"), "foo.co.uk")
        XCTAssertEqual(HostNormalizer.registrableDomain("claude.ai"), "claude.ai")
        XCTAssertEqual(HostNormalizer.registrableDomain("Shop.Example.COM.AU"), "example.com.au")
    }

    func testIconKeySharesBrandsButNotSharedDomains() {
        XCTAssertEqual(HostNormalizer.iconKey(host: "onlinebanking.aib.ie"), "aib.ie")
        XCTAssertEqual(HostNormalizer.iconKey(host: "aib.ie"), "aib.ie")
        XCTAssertEqual(HostNormalizer.iconKey(host: "docs.google.com"), "docs.google.com", "google.com hosts are unrelated services")
        XCTAssertEqual(HostNormalizer.iconKey(host: "shop.myshopify.com"), "shop.myshopify.com")
        XCTAssertEqual(HostNormalizer.iconKey(host: "app.hubspot.com"), "hubspot.com")
    }

    func testBundledMarks() {
        XCTAssertEqual(HostNormalizer.bundledMark(host: "claude.ai"), "claude")
        XCTAssertEqual(HostNormalizer.bundledMark(host: "docs.anthropic.com"), "claude")
        XCTAssertEqual(HostNormalizer.bundledMark(host: "docs.google.com"), "googledocs")
        XCTAssertEqual(HostNormalizer.bundledMark(host: "mail.google.com"), "gmail")
        XCTAssertEqual(HostNormalizer.bundledMark(host: "app.slack.com"), "slack")
        XCTAssertEqual(HostNormalizer.bundledMark(host: "github.com"), "github")
        XCTAssertNil(HostNormalizer.bundledMark(host: "onlinebanking.aib.ie"), "AIB has no bundled mark — the favicon path handles it")
    }

    func testWebURLValidation() {
        XCTAssertEqual(AXReader.webURL("https://claude.ai/chat/abc")?.host, "claude.ai")
        XCTAssertEqual(AXReader.webURL("onlinebanking.aib.ie/inet/roi")?.absoluteString, "https://onlinebanking.aib.ie/inet/roi")
        XCTAssertNil(AXReader.webURL("aib"))
        XCTAssertNil(AXReader.webURL("chrome://newtab"))
        XCTAssertNil(AXReader.webURL("about:blank"))
        XCTAssertNil(AXReader.webURL("how to fix a swift build error"))
        XCTAssertNil(AXReader.webURL("file:///Users/me/report.html"))
    }
}
