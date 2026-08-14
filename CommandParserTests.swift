import XCTest

final class CommandParserTests: XCTestCase {
    func testBenchyColorAndSlot() {
        let command = CommandParser().parse("Hey Jarvis, print a Benchy in red using AMS slot 3")
        XCTAssertEqual(
            command,
            .findAndPrint(query: "benchy", requestedColor: "red", requestedSlot: 3)
        )
    }
}
