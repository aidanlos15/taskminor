import XCTest
@testable import Availeth

final class PromptEchoTests: XCTestCase {
    let ctx = SceneContext(appName: "Code", windowTitle: "Timekeeper clock in behavior", action: "Switched to Code")

    func testEchoOfGroundingLineIsRejected() {
        XCTAssertTrue(OllamaInterpreter.isPromptEcho("App: Code. Window: Timekeeper clock in behavior. The user just: Switched to Code.", context: ctx))
    }

    func testRewordedEchoIsRejected() {
        XCTAssertTrue(OllamaInterpreter.isPromptEcho("The user switched to Code, window Timekeeper clock in behavior.", context: ctx))
    }

    func testRealDescriptionIsKept() {
        XCTAssertFalse(OllamaInterpreter.isPromptEcho("Editing a Swift file in Code with a chat panel open on the right asking about clock-in rules.", context: ctx))
    }
}
