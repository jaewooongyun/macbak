import AppKit
import SwiftUI
import Testing
@testable import Macbak

/// SwiftUI may propose an unbounded width while measuring; converting the column count to `Int` must not trap.
@Test func anUnboundedWidthFitsEveryColumnInsteadOfTrapping() {
    let grid = AdaptiveGrid(minimumColumnWidth: 240, maximumColumns: 3, spacing: 16)
    #expect(grid.fittingColumns(width: .infinity) == 3)
    #expect(grid.fittingColumns(width: .greatestFiniteMagnitude) == 3)
    #expect(grid.fittingColumns(width: 0) == 1)
    #expect(grid.fittingColumns(width: 520) == 2)
}

/// The real measurement path: asked how wide it would grow, the grid answers unbounded like `frame(maxWidth: .infinity)`
/// does, with a finite height.
@MainActor @Test func measuringWithAnUnboundedProposalFillsTheWidthAndKeepsAFiniteHeight() {
    let grid = AdaptiveGrid(minimumColumnWidth: 240, maximumColumns: 3, spacing: 16) {
        Text("CPU")
        Text("GPU")
        Text("메모리").gridSpan(.max)
    }
    let size = NSHostingController(rootView: grid).sizeThatFits(in: CGSize(width: CGFloat.infinity, height: .infinity))
    #expect(size.width == .infinity)
    #expect(size.height.isFinite && size.height > 0)
}
