import Foundation
import Testing
@testable import Macbak

private let now = Date(timeIntervalSince1970: 2_000_000)
private let devices = "/Users/me/Library/Developer/CoreSimulator/Devices"
private func udid(_ c: Character) -> String { String(repeating: c, count: 8) + "-" + String(repeating: c, count: 4) + "-" + String(repeating: c, count: 4) + "-" + String(repeating: c, count: 4) + "-" + String(repeating: c, count: 12) }
private func proc(_ pid: pid_t, _ ppid: pid_t, _ path: String, hoursAgo: Double, gb: Double? = 0.5) -> (pid_t, SimulatorMemory.ProcessInfo) {
    (pid, SimulatorMemory.ProcessInfo(pid: pid, ppid: ppid, path: path, start: now.addingTimeInterval(-hoursAgo * 3600),
                                      memory: gb.map { UInt64($0 * 1_073_741_824) }))
}
private func app(_ device: String) -> String { "\(devices)/\(device)/data/Containers/Bundle/Application/X/sample.app/sample" }

@Test func simulatorsAreIdleOnlyWhenNothingUsesThem() {
    let (a, b, c, d) = (udid("A"), udid("B"), udid("C"), udid("D"))
    let runtime = "/Library/Developer/CoreSimulator/Volumes/iOS/RuntimeRoot/usr/libexec"
    let table = Dictionary(uniqueKeysWithValues: [
        proc(100, 1, runtime + "/launchd_sim", hoursAgo: 20, gb: 0.03), proc(101, 100, runtime + "/backboardd", hoursAgo: 20, gb: 1),
        proc(102, 100, app(a), hoursAgo: 15),
        proc(200, 1, runtime + "/launchd_sim", hoursAgo: 20), proc(201, 200, runtime + "/backboardd", hoursAgo: 20),
        proc(202, 200, app(b), hoursAgo: 10.0 / 60),
        proc(300, 1, runtime + "/launchd_sim", hoursAgo: 20), proc(301, 300, runtime + "/backboardd", hoursAgo: 20),
        proc(400, 1, "/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Resources/debugserver", hoursAgo: 3),
        proc(302, 400, app(c), hoursAgo: 3, gb: 0.7),
        proc(500, 1, runtime + "/launchd_sim", hoursAgo: 20), proc(501, 500, runtime + "/backboardd", hoursAgo: 20),
        proc(600, 1, "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", hoursAgo: 2),
        proc(700, 1, "/System/Library/PrivateFrameworks/DeviceFS.framework/DeviceFS", hoursAgo: 30),
    ])
    let files = [
        SimulatorMemory.OpenFile(pid: 101, path: "\(devices)/\(a)/data/var/run/x"),
        SimulatorMemory.OpenFile(pid: 700, path: "\(devices)/\(a)/data/Library/y"),
        SimulatorMemory.OpenFile(pid: 201, path: "\(devices)/\(b)/data/var/run/x"),
        SimulatorMemory.OpenFile(pid: 301, path: "\(devices)/\(c)/data/var/run/x"),
        SimulatorMemory.OpenFile(pid: 501, path: "\(devices)/\(d)/data/var/run/x"),
        SimulatorMemory.OpenFile(pid: 600, path: "\(devices)/\(d)/data/Containers/Bundle/z"),
    ]
    let found = Dictionary(uniqueKeysWithValues: SimulatorMemory.judge(table, files: files, names: [a: "Idle iPhone"], now: now).map { ($0.udid, $0) })

    #expect(found[a]?.busy == nil)
    #expect(found[a]?.name == "Idle iPhone")
    #expect(found[a]?.setPath == devices)
    #expect(found[a].map { abs(Double($0.memory) / 1_073_741_824 - 1.53) < 0.01 } == true)
    #expect(found[b]?.busy == "최근 1시간 안에 쓰임")
    #expect(found[c]?.busy == "디버거나 테스트가 실행한 앱이 있음")
    #expect(found[c].map { $0.memory >= UInt64(0.7 * 1_073_741_824) } == true)
    #expect(found[d]?.busy == "xcodebuild가 쓰는 중")
    #expect(SimulatorMemory.judge(table, files: files, names: [:], now: now).first?.udid == a)
}

@Test func deviceFolderNeedsARealUDID() {
    let path = "\(devices)/\(udid("E"))/data/var/x"
    #expect(SimulatorMemory.deviceFolder(in: path)?.set == devices)
    #expect(SimulatorMemory.deviceFolder(in: path)?.folder == "\(devices)/\(udid("E"))")
    #expect(SimulatorMemory.deviceFolder(in: "\(devices)/not-a-udid/data") == nil)
}

@Test func anOpenerWhoseDetailsCouldNotBeReadKeepsTheSimulatorBusy() {
    let a = udid("A")
    let runtime = "/Library/Developer/CoreSimulator/Volumes/iOS/RuntimeRoot/usr/libexec"
    let table = Dictionary(uniqueKeysWithValues: [
        proc(100, 1, runtime + "/launchd_sim", hoursAgo: 20), proc(101, 100, runtime + "/backboardd", hoursAgo: 20),
    ])
    // pid 900 holds a device file but is missing from the process table (exited, or its details were unreadable).
    let files = [
        SimulatorMemory.OpenFile(pid: 101, path: "\(devices)/\(a)/data/var/run/x"),
        SimulatorMemory.OpenFile(pid: 900, path: "\(devices)/\(a)/data/Library/y"),
    ]
    #expect(SimulatorMemory.judge(table, files: files, names: [:], now: now).first?.busy == "알 수 없는 프로세스가 쓰는 중")
}
