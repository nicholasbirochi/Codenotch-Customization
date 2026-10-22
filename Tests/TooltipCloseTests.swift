import XCTest
@testable import Codenotch

/// The × on the tooltip card folds the notch, even one kept open.
@MainActor
final class TooltipCloseTests: XCTestCase {
    func testShowWiresTheCloseButton() {
        let controller = NotchWindowController()
        XCTAssertNil(controller.model.onCloseTooltip)
        controller.show()
        defer { controller.stop() }
        XCTAssertNotNil(controller.model.onCloseTooltip, "The card's × needs somewhere to send its tap")
    }

    func testCloseFoldsAndUnpins() {
        let controller = NotchWindowController()
        controller.show()
        defer { controller.stop() }

        controller.model.isExpanded = true
        controller.model.isPinned = true
        controller.model.hoveredIndex = 0

        controller.model.onCloseTooltip?()

        XCTAssertFalse(controller.model.isExpanded, "Closing folds the notch at once")
        XCTAssertFalse(controller.model.isPinned, "Keep open does not outlast an explicit close")
        XCTAssertNil(controller.model.hoveredIndex, "No card is left behind")
    }
}
