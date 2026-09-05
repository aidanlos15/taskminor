import XCTest
@testable import Availeth

final class WorkflowUnitTests: XCTestCase {
    /// Browser tabs resolve to their SITE, not "Chrome" — so distinct tabs are
    /// never lumped together.
    func testBrowserTabsResolveToSite() {
        XCTAssertEqual(WorkflowUnit.label(app: "Google Chrome", title: "Vendor Bills - NetSuite - Google Chrome - Aidan"), "NetSuite")
        XCTAssertEqual(WorkflowUnit.label(app: "Google Chrome", title: "Q3 Pipeline — Salesforce - Google Chrome"), "Salesforce")
        XCTAssertEqual(WorkflowUnit.label(app: "Google Chrome", title: "Feed | LinkedIn - Google Chrome - Aidan"), "LinkedIn")
        XCTAssertEqual(WorkflowUnit.label(app: "Google Chrome", title: "Aidan O'Sullivan | Base44 - Google Chrome - Aidan"), "Base44")
        XCTAssertEqual(WorkflowUnit.label(app: "Safari", title: "Temu | Shop Like a Billionaire"), "Temu")
    }

    /// Two different sites in the same browser are DIFFERENT units.
    func testDistinctSitesAreDistinctUnits() {
        let netsuite = WorkflowUnit.label(app: "Google Chrome", title: "Vendor Bills - NetSuite - Google Chrome")
        let temu = WorkflowUnit.label(app: "Google Chrome", title: "Temu - Google Chrome")
        XCTAssertNotEqual(netsuite, temu)
    }

    /// Non-browser apps keep their (shortened) app name.
    func testNonBrowserAppsKeepAppName() {
        XCTAssertEqual(WorkflowUnit.label(app: "Microsoft Excel", title: "Purchase Orders.xlsx"), "Excel")
        XCTAssertEqual(WorkflowUnit.label(app: "Mail", title: "Inbox"), "Mail")
        XCTAssertEqual(WorkflowUnit.label(app: "Claude", title: "Claude"), "Claude")
    }

    /// A page title with no site convention falls back to its own identity, not
    /// a shared "Chrome" bucket.
    func testUnknownPageKeepsOwnIdentity() {
        let unit = WorkflowUnit.label(app: "Google Chrome", title: "Hotel Profitability Strategy - Google Chrome - Aidan")
        XCTAssertNotEqual(unit, "Chrome")
        XCTAssertTrue(unit.contains("Hotel"))
    }
}
