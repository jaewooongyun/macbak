import Testing
@testable import Macbak

/// The line under the disk's capacity about the expanded scan.
@MainActor
@Suite struct DiskScreenTextTests {
    static let walking = "홈 폴더의 프로젝트까지 찾는 중입니다. 3~4분 걸리고, 찾는 대로 목록에 더합니다."

    @Test func whileTheWalkRunsItSaysHowLongEvenOverAnOlderResult() {
        #expect(DiskScreen.discoveryText(scanningProjects: true, discovery: nil) == Self.walking)
        #expect(DiskScreen.discoveryText(scanningProjects: true, discovery: ProjectDiscovery.Result()) == Self.walking)
    }

    @Test func afterItSaysWhatItDidNotLookAtAndWhetherItRanOut() {
        var found = ProjectDiscovery.Result()
        found.skipped = ["휴지통", "링크 1곳"]
        #expect(DiskScreen.discoveryText(scanningProjects: false, discovery: found) == "검사하지 않은 곳: 휴지통 · 링크 1곳")
        found.partial = true
        #expect(DiskScreen.discoveryText(scanningProjects: false, discovery: found)
            == "프로젝트 검사는 시간이 다 돼 일부만 봤습니다. 검사하지 않은 곳: 휴지통 · 링크 1곳")
    }

    @Test func beforeAnyItSaysNothing() {
        #expect(DiskScreen.discoveryText(scanningProjects: false, discovery: nil) == nil)
    }
}
