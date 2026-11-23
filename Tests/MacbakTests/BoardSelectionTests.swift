import SwiftUI
import Testing
@testable import Macbak

/// The dashboard's ticks when rows come or go, as when the expanded scan adds its rows minutes after the usual ones.
@MainActor
@Suite struct BoardSelectionTests {
    typealias Board = CleanupBoard<EmptyView>

    static func manual(_ id: String) -> CleanupCandidate {
        var row = ScanReportTests.row(id)
        row.manualOnly = true
        return row
    }

    /// The person unticked A and ticked M; then B (ticked to begin with) and C (picked by hand) arrive and D goes.
    @Test func ticksThePersonChangedStayAndNewTickedRowsJoin() {
        let before = [ScanReportTests.row("A"), Self.manual("M"), ScanReportTests.row("D")]
        let selected: Set<String> = ["M"]
        let after = [ScanReportTests.row("A"), Self.manual("M"), ScanReportTests.row("B"), Self.manual("C")]
        #expect(Board.kept(selected, idsBefore: before.map(\.id), rows: after) == ["M", "B"])
    }

    /// A ticked row that now waits for a hand pick (as one the borrower memory can no longer vouch for) loses its tick,
    /// whichever of the two changes the board sees first; the row the person unticked (U) stays unticked.
    @Test func aRowThatNowWaitsForAHandPickIsUnticked() {
        let before = [ScanReportTests.row("A"), ScanReportTests.row("B"), ScanReportTests.row("U")]
        let after = [Self.manual("A"), ScanReportTests.row("B"), ScanReportTests.row("U"), ScanReportTests.row("N")]
        let preselected = Board.preselected(before)
        let first = Board.reselect(["A", "B"], preselectedBefore: preselected, rows: after)
        #expect(Board.kept(first, idsBefore: before.map(\.id), rows: after) == ["B", "N"])
        let other = Board.kept(["A", "B"], idsBefore: before.map(\.id), rows: after)
        #expect(Board.reselect(other, preselectedBefore: preselected, rows: after) == ["B", "N"])
    }

    @Test func aRowThatCanNoLongerBeChosenIsUnticked() {
        let before = [Self.manual("M"), ScanReportTests.row("A")]
        let after = [ScanReportTests.row("M", selectable: false), ScanReportTests.row("A")]
        #expect(Board.kept(["M", "A"], idsBefore: before.map(\.id), rows: after) == ["A"])
    }
}
