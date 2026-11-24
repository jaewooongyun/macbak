import Foundation
import Testing
@testable import Macbak

/// Virtual machines and emulators, told apart by their executable's path alone and only ever shown.
@Suite struct DevMachineTests {
    private func snapshot(_ entries: [ProcessSnapshot.Entry]) -> ProcessSnapshot {
        ProcessSnapshot(entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) }), taken: .now)
    }

    private func entry(_ pid: pid_t, _ path: String?, name: String? = nil, footprint: UInt64 = 1_000_000) -> ProcessSnapshot.Entry {
        ProcessSnapshot.Entry(pid: pid, path: path, name: name ?? path.map { ($0 as NSString).lastPathComponent }, footprint: footprint)
    }

    static let vz = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

    @Test func androidEmulatorIsFoundByItsExecutablePath() {
        let found = DevMachines.find(snapshot([entry(10, "/opt/android-sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64")]),
                                     owners: nil, apps: [:])
        #expect(found.map(\.kind) == [.androidEmulator])
        #expect(found.first?.title == "Android 에뮬레이터")
        #expect(found.first?.howToStop.contains("Device Manager") == true)
    }

    @Test func appleVirtualMachinesAreNamedAfterTheirOwnerApp() {
        let found = DevMachines.find(snapshot([entry(20, Self.vz, footprint: 8_000_000_000), entry(21, Self.vz, footprint: 2_000_000_000)]),
                                     owners: [20: 5, 21: 99], apps: [5: "/Applications/Docker.app"])
        #expect(found.map(\.pid) == [20, 21], "largest first")
        #expect(found.map(\.title) == ["Docker 가상 머신", "가상 머신"])
        #expect(found.first?.howToStop == "Docker에서 끄세요.")
        #expect(found.last?.owner == nil, "an owner that is not a running app is not guessed")
    }

    @Test func otherQemuAndHypervisorsAreFound() {
        let found = DevMachines.find(snapshot([
            entry(30, "/opt/homebrew/Cellar/qemu/9.2.0/bin/qemu-system-aarch64"),
            entry(31, "/Applications/Parallels Desktop.app/Contents/MacOS/Parallels VM.app/Contents/MacOS/prl_vm_app"),
            entry(32, "/Applications/VMware Fusion.app/Contents/Library/vmware-vmx"),
        ]), owners: nil, apps: [:])
        #expect(Set(found.map(\.kind)) == [.qemu, .parallels, .vmware])
    }

    /// A process whose path could not be read is not judged by its kernel name, nor is one whose name alone looks like
    /// a machine.
    @Test func processesWithoutAReadablePathAreLeftOut() {
        let found = DevMachines.find(snapshot([
            entry(40, nil, name: "qemu-system-aarch64"),
            entry(41, "/usr/bin/python3", name: "qemu-system-x86_64"),
        ]), owners: nil, apps: [:])
        #expect(found.isEmpty)
    }

    @Test func unrelatedProcessesAreNotMachines() {
        let found = DevMachines.find(snapshot([
            entry(50, "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            entry(51, "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.EventTap.xpc/Contents/MacOS/com.apple.Virtualization.EventTap"),
            entry(52, "/tmp/com.apple.Virtualization.VirtualMachine"),
            entry(53, "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/launchd_sim"),
        ]), owners: nil, apps: [:])
        #expect(found.isEmpty)
    }

    @Test func theMachineCardShowsOnlyWhenOneRuns() {
        #expect(!MemoryScreen.showsMachines([]))
        #expect(MemoryScreen.showsMachines([DevMachine(pid: 1, kind: .qemu, owner: nil, footprint: nil)]))
    }
}
