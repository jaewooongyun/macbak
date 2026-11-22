import Testing
@testable import Macbak

@Test func unverifiedEvidenceFailsClosed() {
    let checked = Evidence(verified: true, inUse: false, regenerable: true)
    #expect(evaluate(checked).status == .ready)

    #expect(evaluate(Evidence()).status == .protected)
    #expect(evaluate(Evidence(verified: nil, inUse: false, regenerable: true)).status == .protected)
    #expect(evaluate(Evidence(verified: true, inUse: nil, regenerable: true)).status == .protected)
    #expect(evaluate(Evidence(verified: true, inUse: false, regenerable: nil)).status == .protected)
}
