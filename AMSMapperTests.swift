import XCTest

final class AMSMapperTests: XCTestCase {
    func testExplicitSlotWins() {
        let printFilament = PrintFilament(id: "f1", name: "Red", material: "PLA", requestedColorName: "red")
        let ams = AMSState(filaments: [
            AMSFilament(id: "a1", slot: 1, material: "PLA", colorName: "red", hexColor: "ff0000", isLoaded: true),
            AMSFilament(id: "a3", slot: 3, material: "PLA", colorName: "red", hexColor: "ff0000", isLoaded: true)
        ])
        let mappings = AMSMapper().suggestMappings(printFilaments: [printFilament], ams: ams, requestedSlot: 3)
        XCTAssertEqual(mappings.first?.amsSlot, 3)
    }
}
