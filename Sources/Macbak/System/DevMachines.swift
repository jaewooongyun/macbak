import Foundation

/// A virtual machine or emulator running on this Mac. Its memory is usually the largest share a development setup
/// holds, and it is stopped in the tool that started it, which the memory screen names; Macbak never stops one.
struct DevMachine: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case androidEmulator, appleVirtualization, qemu, parallels, vmware
    }

    let pid: pid_t
    let kind: Kind
    /// The app it works for, when the system names one (Docker, UTM, OrbStack and the like).
    let owner: String?
    let footprint: UInt64?

    var id: pid_t { pid }

    var title: String {
        switch kind {
        case .androidEmulator: "Android 에뮬레이터"
        case .appleVirtualization: owner.map { "\($0) 가상 머신" } ?? "가상 머신"
        case .qemu: "QEMU 가상 머신"
        case .parallels: "Parallels 가상 머신"
        case .vmware: "VMware 가상 머신"
        }
    }

    var howToStop: String {
        switch kind {
        case .androidEmulator: "에뮬레이터 창을 닫거나 Android Studio의 Device Manager에서 끄세요."
        case .appleVirtualization: owner.map { "\($0)에서 끄세요." } ?? "이 가상 머신을 띄운 앱에서 끄세요."
        case .qemu: "띄운 도구(colima stop, limactl stop, UTM 등)에서 끄세요."
        case .parallels: "Parallels Desktop에서 끄세요."
        case .vmware: "VMware Fusion에서 끄세요."
        }
    }
}

/// Finds virtual machines and emulators by their executable's path alone; arguments are never read.
enum DevMachines {
    /// What the executable at `path` runs, or nil when it is none of the known machines.
    static func kind(path: String) -> DevMachine.Kind? {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix("qemu-system"), path.contains("/emulator/qemu/") { return .androidEmulator }
        if name == "com.apple.Virtualization.VirtualMachine", path.hasPrefix("/System/Library/Frameworks/Virtualization.framework/") { return .appleVirtualization }
        if name.hasPrefix("qemu-system") { return .qemu }
        if name == "prl_vm_app" { return .parallels }
        if name == "vmware-vmx" { return .vmware }
        return nil
    }

    /// Every machine in the snapshot, largest first. A process whose path could not be read is left out.
    /// - Parameters:
    ///   - owners: each process's responsible process, when the system said.
    ///   - apps: each running app's pid and bundle folder.
    static func find(_ snapshot: ProcessSnapshot, owners: [pid_t: pid_t]?, apps: [pid_t: String?]) -> [DevMachine] {
        snapshot.entries.values.compactMap { entry -> DevMachine? in
            guard let path = entry.path, let kind = kind(path: path) else { return nil }
            let owner = owners?[entry.pid].flatMap { apps[$0] ?? nil }.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            return DevMachine(pid: entry.pid, kind: kind, owner: owner, footprint: entry.footprint)
        }
        .sorted { ($0.footprint ?? 0, $1.pid) > ($1.footprint ?? 0, $0.pid) }
    }
}
