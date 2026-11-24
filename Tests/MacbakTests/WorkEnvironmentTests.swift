import Foundation
import Testing
@testable import Macbak

/// What the Mac is used for, read from marker folders and app names only. It changes what is shown, never a verdict.
@Suite struct WorkEnvironmentTests {
    @Test func aHomeWithNoMarkersAndNoAppsFindsNothing() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let found = WorkEnvironment.detect(home: box.root, applications: [])
        #expect(found.kinds.isEmpty)
        #expect(found.summary.isEmpty)
        #expect(DiskScreen.environmentText(found) == nil)
        #expect(DiskScreen.environmentText(nil) == nil)
    }

    /// Each kind's first home marker alone finds that kind and no other, so one kind's markers never stand for another's.
    @Test(arguments: WorkEnvironment.Kind.allCases.filter { !$0.homeMarkers.isEmpty })
    func eachHomeMarkerFindsItsOwnKind(kind: WorkEnvironment.Kind) throws {
        for marker in kind.homeMarkers {
            let box = try Sandbox()
            defer { box.remove() }
            try box.folder(marker)
            #expect(WorkEnvironment.detect(home: box.root, applications: []).kinds == [kind], "\(marker)")
        }
    }

    /// The agreed markers, written out apart from the product's lists: dropping one from the product fails here.
    static let agreedMarkers: [(String, WorkEnvironment.Kind)] = [
        ("Library/Developer/Xcode", .apple), ("Library/Developer/CoreSimulator", .apple),
        (".android", .android), ("Library/Android/sdk", .android),
        (".npm", .web), (".nvm", .web), (".volta", .web), (".bun", .web), (".yarn", .web), ("Library/pnpm", .web), ("Library/Caches/Yarn", .web),
        (".pyenv", .python), (".conda", .python), ("miniconda3", .python), ("anaconda3", .python), (".local/share/uv", .python),
        (".cache/uv", .python), ("Library/Caches/pip", .python), (".jupyter", .python),
        (".m2", .jvm), (".sdkman", .jvm), (".ivy2", .jvm),
        ("go/pkg", .go), ("Library/Caches/go-build", .go),
        (".cargo", .rust), (".rustup", .rust),
        (".gem", .ruby), (".rbenv", .ruby), (".rvm", .ruby),
        (".composer", .php), ("Library/Caches/composer", .php),
        (".nuget", .dotnet), (".dotnet", .dotnet),
        (".docker", .containers), (".orbstack", .containers), (".colima", .containers), (".lima", .containers), ("Library/Containers/com.docker.docker", .containers),
        (".ollama", .localAI), (".lmstudio", .localAI), (".cache/huggingface", .localAI),
        ("Library/Unity", .gameEngine), ("Library/Application Support/Unity", .gameEngine), ("Library/Application Support/Epic", .gameEngine),
        ("Library/Application Support/Figma", .design), ("Library/Application Support/com.bohemiancoding.sketch3", .design),
        ("Library/Application Support/Blender", .design), ("Library/Application Support/Adobe/Common", .design),
        ("Library/Application Support/Blackmagic Design", .video),
    ]

    @Test func theAgreedMarkersEachFindTheirKind() throws {
        for (marker, kind) in Self.agreedMarkers {
            let box = try Sandbox()
            defer { box.remove() }
            try box.folder(marker)
            #expect(WorkEnvironment.detect(home: box.root, applications: []).kinds == [kind], "\(marker)")
        }
    }

    /// App names are matched by their start, so a versioned Xcode and a suite's folder count; apps every new Mac has,
    /// and an Adobe app that is not a design tool, do not.
    @Test func appNamesAreMatchedByTheirStart() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let found = WorkEnvironment.detect(home: box.root, applications: ["Xcode-26.1", "Adobe Photoshop 2026", "GarageBand", "iMovie",
                                                                          "Adobe Acrobat Reader", "Safari", "Logic Pro"])
        #expect(found.kinds == [.apple, .design, .audio])
        #expect(found.summary == "iOS·macOS 개발 · 디자인 · 음악 제작")
    }

    /// A marker that is a link counts as itself: its target is never followed, so a dangling one still counts.
    @Test func aLinkedMarkerCountsWithoutBeingFollowed() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.link(".cargo", to: box.root.appending(path: "missing-target"))
        #expect(WorkEnvironment.detect(home: box.root, applications: []).kinds == [.rust])
    }

    @Test func installedAppNamesDropTheAppSuffix() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.folder("Applications/Figma.app")
        try box.folder("Applications/DaVinci Resolve")
        #expect(Set(WorkEnvironment.installedAppNames(in: [box.root.appending(path: "Applications").path(percentEncoded: false), "/nonexistent"]))
                == ["Figma", "DaVinci Resolve"])
    }

    /// Kinds come out in one fixed order, whatever order they were found in.
    @Test func kindsKeepTheirDeclaredOrder() {
        #expect(WorkEnvironment(kinds: [.design, .apple, .rust, .design]).kinds == [.apple, .rust, .design])
    }

    /// Apple-only areas are named only on a Mac with Apple tools, and every area is named while that is unknown.
    @Test func appleAreasAreNamedOnlyWhereAppleToolsAre() {
        let android = WorkEnvironment(kinds: [.android])
        let apple = WorkEnvironment(kinds: [.apple])
        for area in CleanupCoordinator.Area.allCases {
            let appleOnly = [.xcode, .devices, .runtimes].contains(area)
            #expect(area.applies(to: android) == !appleOnly, "\(area)")
            #expect(area.applies(to: apple))
            #expect(area.applies(to: nil))
        }
    }

    @Test func theSimulatorCardShowsOnAppleMacsOrWhenASimulatorIsOn() {
        let booted = BootedSimulator(udid: "A", name: "iPhone", setPath: "/x", memory: 1, lastActivity: .now, busy: nil)
        #expect(MemoryScreen.showsSimulators(nil, nil))
        #expect(MemoryScreen.showsSimulators(WorkEnvironment(kinds: [.apple]), []))
        #expect(!MemoryScreen.showsSimulators(WorkEnvironment(kinds: [.android]), []))
        #expect(!MemoryScreen.showsSimulators(WorkEnvironment(kinds: []), nil))
        #expect(MemoryScreen.showsSimulators(WorkEnvironment(kinds: [.android]), [booted]))
    }
}
