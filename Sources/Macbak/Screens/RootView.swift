import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case glance, disk, memory, aiActivity, aiStorage, loop

    var id: Self { self }

    var title: String {
        switch self {
        case .glance: "한눈에"
        case .disk: "디스크"
        case .memory: "메모리"
        case .aiActivity: "AI 활동"
        case .aiStorage: "AI 저장 공간"
        case .loop: "루프"
        }
    }

    var symbol: String {
        switch self {
        case .glance: "waveform.path.ecg"
        case .disk: "internaldrive"
        case .memory: "memorychip"
        case .aiActivity: "text.bubble"
        case .aiStorage: "archivebox"
        case .loop: "clock.arrow.circlepath"
        }
    }

    /// The sidebar badge colour. Hues follow the section (blue and green for the system, indigo and purple for AI) and
    /// match the screen's own main colour where it has one: the disk ring is blue, a calm memory ring is green.
    var tint: Color {
        switch self {
        case .glance: .pink
        case .disk: .blue
        case .memory: .green
        case .aiActivity: .indigo
        case .aiStorage: .purple
        case .loop: .teal
        }
    }

    /// Sidebar sections. The glance screen stands alone above them because it covers all of them.
    static let sections: [(title: String, screens: [Screen])] = [
        ("시스템", [.disk, .memory]),
        ("AI", [.aiActivity, .aiStorage]),
        ("자동화", [.loop]),
    ]
}

struct ContentView: View {
    @Environment(SystemMonitor.self) private var system
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Screen?
    /// A screen growing out of a tapped tile, and the screen it leaves behind.
    @State private var zoom: Zoom?
    @State private var detailSize = CGSize.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False while the window is closed or minimized. A closed `Window` scene keeps its views alive, so without this
    /// the hidden screen kept re-rendering on every sample.
    @State private var shown = true

    init(selection: Screen = .glance) {
        _selection = State(initialValue: selection)
    }

    /// App Store-style opening: the new screen grows out of the tapped tile to fill the column under frosted Liquid Glass
    /// that clears as it grows, while the screen behind sinks back. One continuous motion.
    /// Reduce Motion switches straight away.
    private func expand(to screen: Screen, from frame: CGRect) {
        guard !reduceMotion, zoom == nil, frame.width > 0, detailSize.width > 0 else {
            if zoom == nil { selection = screen }
            return
        }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            zoom = Zoom(leaving: selection ?? .glance, from: frame)
            selection = screen
        }
        // Even pace (not a fast-start spring), so the frosted stretch lasts long enough to be seen.
        withAnimation(.timingCurve(0.3, 0.1, 0.25, 1, duration: 0.35)) {
            zoom?.progress = 1
        } completion: {
            withTransaction(instant) { zoom = nil }
        }
    }

    /// Shows the screen asked for from the menu bar, without a zoom, and clears the request.
    private func takeRequest() {
        guard let requested = navigation.requested else { return }
        navigation.requested = nil
        zoom = nil
        selection = requested
    }

    /// The pages on screen: during a zoom the page left behind stays, under the growing one. Keyed by screen, so the
    /// page left behind keeps its identity and nothing on it restarts.
    private var pages: [Screen] {
        let current = selection ?? .glance
        guard let leaving = zoom?.leaving, leaving != current else { return [current] }
        return [leaving, current]
    }

    @ViewBuilder
    private func page(_ screen: Screen) -> some View {
        switch screen {
        case .glance: GlanceScreen(open: expand)
        case .disk: DiskScreen()
        case .memory: MemoryScreen()
        case .aiActivity: AIActivityScreen()
        case .aiStorage: AIStorageScreen()
        case .loop: LoopScreen()
        }
    }

    var body: some View {
        NavigationSplitView {
            LiquidSidebar(selection: Binding(get: { selection ?? .glance }, set: { selection = $0 }))
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                HStack(alignment: .top, spacing: 10) {
                    SidebarBadge(symbol: "checkmark.shield", tint: .gray)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("확인 뒤 정리").font(.callout.weight(.semibold))
                        Text("지울 목록을 먼저 보여 주고, 지우기 직전에 하나씩 다시 확인합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        } detail: {
            ZStack(alignment: .topLeading) {
                if shown {
                    ForEach(pages, id: \.self) { screen in
                        let growing = zoom != nil && screen == selection
                        let leaving = zoom?.leaving == screen && screen != selection
                        page(screen)
                            // A page growing from a tile is complete from its first frame; the growth is its entrance.
                            .environment(\.arrivesInPlace, growing)
                            .modifier(ZoomFromTile(progress: growing ? zoom?.progress ?? 1 : 1,
                                                   from: growing ? zoom?.from ?? .zero : .zero, bounds: detailSize))
                            // Steps back into depth: smaller, under a darkening veil (a veil, not transparency, so light mode
                            // sinks too instead of washing out).
                            .scaleEffect(leaving ? 1 - 0.08 * (zoom?.progress ?? 0) : 1)
                            .overlay { if leaving { Color.black.opacity(0.28 * (zoom?.progress ?? 0)).allowsHitTesting(false) } }
                            .allowsHitTesting(!leaving)
                            .zIndex(screen == selection ? 1 : 0)
                            .transition(.blurReplace)
                    }
                }
            }
            .coordinateSpace(.named(DetailSpace.name))
            .animatesOnlyWhenShown()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { detailSize = $0 }
            // Sidebar switches dissolve through a blur; a zoom changes the selection without animation and grows instead.
            .animation(reduceMotion ? nil : Theme.stateChange, value: selection)
            .navigationTitle((selection ?? .glance).title)
            .toolbar {
                if shown { PulsePill { selection = .glance } }
                Button { system.refreshAll() } label: {
                    Label("새로 고침", systemImage: "arrow.clockwise")
                }
                .help("디스크와 메모리를 다시 읽습니다 (⌘R)")
            }
        }
        .background(WindowShownReader(shown: $shown))
        .onAppear {
            MainWindow.open = openWindow
            takeRequest()
        }
        .onChange(of: navigation.requested) { takeRequest() }
    }
}

/// The pulse in the toolbar, on every screen. Toolbar items sit on Liquid Glass on macOS 26 and later.
private struct PulsePill: View {
    @Environment(SystemMonitor.self) private var system
    let action: () -> Void

    var body: some View {
        let reading = system.vitals.isEmpty ? nil : PulseReading(loads: system.vitals.map(\.load))
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "heart.fill").foregroundStyle(.pink)
                Text(reading.map { "\($0.bpm) · \($0.mood.title)" } ?? "맥박 재는 중").monospacedDigit()
            }
        }
        .help(PulseReading.explanation)
        .accessibilityLabel(reading.map { "맥박 \($0.bpm), \($0.mood.title)" } ?? "맥박 재는 중")
    }
}

/// A tile on its way to becoming a screen.
struct Zoom {
    let leaving: Screen
    let from: CGRect
    var progress = 0.0
}

/// Grows a page out of a tapped tile under a frosted pane. The page is opaque from the first frame, drawn full size,
/// scaled to the pane's width and clipped to its rounded shape; the pane on top shows it only faintly until the last
/// stretch, then clears.
/// - Note: Animatable, so SwiftUI interpolates `progress` and every frame recomputes one consistent rect; animating the
///   scale, offset, clip and glass separately would let them drift apart mid-flight.
/// - Important: The pane is not Liquid Glass. Glass takes its colour from what lies under it and eases into it over time,
///   so at full speed it was still carrying the green of the memory tile and chart for the whole zoom (slow motion hid
///   it: the glass had time to settle). A blur on the page itself re-rendered it offscreen with dark-mode colours
///   resolved as light.
struct ZoomFromTile: ViewModifier, Animatable {
    var progress: Double
    let from: CGRect
    let bounds: CGSize

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// 0 until `start`, 1 from `end`, eased in between.
    private func ramp(_ t: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
        let x = min(max((t - start) / (end - start), 0), 1)
        return x * x * (3 - 2 * x)
    }

    func body(content: Content) -> some View {
        let full = CGRect(origin: .zero, size: bounds)
        let t = CGFloat(min(max(progress, 0), 1))
        // Active for the whole zoom, including its last frame at t = 1: the opaque backing must stay until the screen
        // left behind is removed in the same update, or that screen showed through the new one for a frame and jumped.
        let active = from.width > 0 && bounds.width > 0
        let rect = active ? CGRect(x: from.minX + (full.minX - from.minX) * t, y: from.minY + (full.minY - from.minY) * t,
                                   width: from.width + (full.width - from.width) * t,
                                   height: from.height + (full.height - from.height) * t) : full
        let scale = active ? max(rect.width / bounds.width, 0.01) : 1
        let screenRadius = Theme.cardRadius * (1 - t)
        // Frosted at first, clearing from about a third of the way, so the page reads for most of the zoom. A strong page
        // colour can show through a thin frost; if it does in slow motion, start later (0.5 at most).
        let frost = active ? 1 - ramp(t, 0.35, 1) : 0
        content
            .frame(width: active ? bounds.width : nil, height: active ? bounds.height : nil, alignment: .topLeading)
            // The window's own background style, not `windowBackgroundColor`: the window is tinted by the desktop
            // (bluish here), and the flat colour drew the growing page plain grey, which read as green beside it until
            // the backing came off at the end.
            .background { if active { Rectangle().fill(.windowBackground) } }
            // Same modifier either way, branching inside: removing the mask at rest would change the page's identity and
            // reset its state.
            .mask(alignment: .topLeading) {
                if active {
                    RoundedRectangle(cornerRadius: screenRadius / scale, style: .continuous)
                        .frame(width: bounds.width, height: rect.height / scale)
                } else {
                    Rectangle().ignoresSafeArea()
                }
            }
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: active ? rect.minX : 0, y: active ? rect.minY : 0)
            // Window-space layers (a background or overlay sits at the untransformed frame), so they are never scaled.
            .background(alignment: .topLeading) {
                if active {
                    RoundedRectangle(cornerRadius: screenRadius, style: .continuous)
                        .fill(.windowBackground)
                        .frame(width: rect.width, height: rect.height)
                        .shadow(color: .black.opacity(0.32 * Double(1 - t)), radius: 28, y: 14)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .overlay(alignment: .topLeading) {
                if active {
                    FrostPane(cornerRadius: screenRadius)
                        .frame(width: rect.width, height: rect.height)
                        .opacity(frost)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The frost over a growing page: a wash of the window background (desktop tint included).
/// - Important: Fixed colours only. Nothing here samples what is beneath it, so the pane can never take on the
///   colour of the page or the tile at any speed.
private struct FrostPane: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.windowBackground.opacity(0.7))
    }
}

/// The sidebar: tinted tiles in a fixed column, and the selection as one neutral drop that stretches from row to row —
/// the edge in the direction of travel leaves first and the other catches up. Up and down arrows move the selection.
/// - Note: A custom list rather than `List`, whose system highlight is one accent-blue bar that jumps between rows and
///   fights the coloured tiles.
private struct LiquidSidebar: View {
    @Binding var selection: Screen

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    /// Each row's frame in the rows' own coordinate space.
    @State private var frames: [Screen: CGRect] = [:]
    /// The drop's top and bottom edges, each animated by its own modifier (`TopEdge`, `BottomEdge`).
    @State private var dropTop: CGFloat = 0
    @State private var dropBottom: CGFloat = 0
    /// The row the drop was last put on; nil until the rows have been measured.
    @State private var placed: Screen?
    /// Selections per row. Only the newly selected row's count changes, so only its symbol bounces: one shared count
    /// on the selected row would not change for that row, and one on every row would bounce the row being left too.
    @State private var bounces: [Screen: Int] = [:]
    @State private var pressingSelected = false

    /// Read from the geometry closure, which runs off the main actor.
    nonisolated private static let space = "sidebar"
    private static var order: [Screen] { [.glance] + Screen.sections.flatMap(\.screens) }

    var body: some View {
        // No glass container here: one composites its glass above the rows' content and hid the selected title.
        // No ScrollView either: in the sidebar it drew its content one toolbar height (52pt) below where clicks landed,
        // so every click picked the row above what it showed. Six rows always fit.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                row(.glance)
                ForEach(Screen.sections, id: \.title) { section in
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.screens) { row($0) }
                }
            }
            // Drawn from measured row frames, so it sits behind the rows rather than beside them: a sibling sized from
            // its own measurements feeds back into the layout it measures.
            .background(alignment: .top) {
                GeometryReader { proxy in
                    SidebarDrop(pressed: pressingSelected && !reduceMotion)
                        .modifier(TopEdge(dropTop: dropTop))
                        .modifier(BottomEdge(dropBottom: dropBottom, height: proxy.size.height))
                }
                .opacity(placed == nil ? 0 : 1)
            }
            .coordinateSpace(.named(Self.space))
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        // Every way the selection changes (a row, the arrow keys, a glance tile, the menu bar, the pulse pill) ends here.
        .onChange(of: selection) { old, new in
            if !reduceMotion { bounces[new, default: 0] += 1 }
            moveDrop(from: old, to: new)
        }
        .onChange(of: frames) { settleDrop() }
    }

    private func row(_ screen: Screen) -> some View {
        SidebarRow(screen: screen, selected: selection == screen, bounce: bounces[screen, default: 0]) {
            selection = screen
        } pressed: { pressing in
            pressingSelected = pressing && selection == screen
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[screen] = $0 }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard let index = Self.order.firstIndex(of: selection) else { return .ignored }
        selection = Self.order[min(max(index + offset, 0), Self.order.count - 1)]
        return .handled
    }

    /// Moves the drop to the newly selected row: going down, the bottom edge leaves first and the top follows; going up,
    /// the reverse. A new selection mid-move carries on from where the edges are drawn.
    private func moveDrop(from old: Screen, to new: Screen) {
        guard let target = frames[new] else {
            placed = nil
            return
        }
        placed = new
        guard !reduceMotion, let start = frames[old] else { return place(target) }
        let down = target.minY > start.minY
        withAnimation(down ? Theme.dropLead : Theme.dropTrail) { dropBottom = target.maxY }
        withAnimation(down ? Theme.dropTrail : Theme.dropLead) { dropTop = target.minY }
    }

    /// Puts the drop on the selected row without animation: the first layout, and a selected row that moved or
    /// resized (the sidebar size setting, the window, the text size).
    private func settleDrop() {
        guard placed == nil || placed == selection, let frame = frames[selection] else { return }
        placed = selection
        if dropTop != frame.minY || dropBottom != frame.maxY { place(frame) }
    }

    private func place(_ frame: CGRect) {
        withTransaction(\.disablesAnimations, true) {
            dropTop = frame.minY
            dropBottom = frame.maxY
        }
    }

    /// The drop's top edge as an animated value of its own.
    /// - Important: Plain `.padding(.top, dropTop)` and `.padding(.bottom, …)` on the drop do not keep two timings: the
    ///   drop's frame is one animated geometry, so the later `withAnimation` carried both edges (measured with
    ///   `DropEdges`, ten times slower: plain paddings moved the edges together; these modifiers let the leading edge
    ///   run up to 18% ahead).
    private struct TopEdge: ViewModifier, Animatable {
        var dropTop: CGFloat

        nonisolated var animatableData: CGFloat {
            get { dropTop }
            set { dropTop = newValue }
        }

        func body(content: Content) -> some View { content.padding(.top, dropTop) }
    }

    /// The drop's bottom edge as an animated value of its own; see `TopEdge`.
    private struct BottomEdge: ViewModifier, Animatable {
        var dropBottom: CGFloat
        let height: CGFloat

        nonisolated var animatableData: CGFloat {
            get { dropBottom }
            set { dropBottom = newValue }
        }

        func body(content: Content) -> some View { content.padding(.bottom, max(height - dropBottom, 0)) }
    }
}

/// Row measurements for the sidebar size in System Settings > Appearance.
private struct SidebarMetrics {
    let font: Font
    let tile: CGFloat
    let symbol: CGFloat
    let padding: CGFloat

    init(_ size: SidebarRowSize) {
        switch size {
        case .small: (font, tile, symbol, padding) = (.callout, 20, 10, 4)
        case .large: (font, tile, symbol, padding) = (.title3, 28, 14, 8)
        default: (font, tile, symbol, padding) = (.body, 24, 12, 6)
        }
    }
}

/// One sidebar entry: tile, title and, at the end, the row's value when it has one.
private struct SidebarRow: View {
    let screen: Screen
    let selected: Bool
    let bounce: Int
    let action: () -> Void
    let pressed: (Bool) -> Void

    @Environment(\.sidebarRowSize) private var size
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let metrics = SidebarMetrics(size)
        Button(action: action) {
            HStack(spacing: 10) {
                SidebarBadge(symbol: screen.symbol, tint: screen.tint, selected: selected, side: metrics.tile,
                             symbolSize: metrics.symbol)
                    .symbolEffect(.bounce, value: bounce)
                Text(screen.title)
                    .font(metrics.font.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                SidebarValue(screen: screen)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, metrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background {
                if hovering && !selected { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary) }
            }
        }
        .buttonStyle(SidebarPress(reduceMotion: reduceMotion, pressed: pressed))
        .onHover { hovering = $0 }
        .animation(Theme.stateChange, value: hovering)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A pressed row sinks a little and says so, so the sidebar can press the drop under the selected row with it.
private struct SidebarPress: ButtonStyle {
    let reduceMotion: Bool
    let pressed: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : Theme.press, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressing in pressed(pressing) }
    }
}

/// The selection: one neutral drop, the same on every screen, so the row's tile carries the only colour.
private struct SidebarDrop: View {
    let pressed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape.fill(Color.primary.opacity(0.09))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .scaleEffect(x: pressed ? 0.985 : 1, y: pressed ? 0.94 : 1)
            .animation(Theme.press, value: pressed)
    }
}

/// The quiet value at the end of a row. Each row reads only its own source, so a change redraws that one value; none
/// of them reads the 2-second samples. VoiceOver reads it after the row's title.
private struct SidebarValue: View {
    let screen: Screen

    @Environment(CleanupCoordinator.self) private var cleanup
    @Environment(AIStorage.self) private var storage
    @Environment(AIMonitor.self) private var ai
    @Environment(LoopScheduler.self) private var loop

    var body: some View {
        if let text {
            Text(text).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var text: String? {
        switch screen {
        case .disk:
            // What the disk screen ticks to begin with: rows that passed every check and need no choice. Empty until a
            // scan has run (the disk screen, the menu bar or the loop); the sidebar never starts one.
            let bytes = (cleanup.all + (storage.report?.candidates ?? [])).filter(\.isPreselected).reduce(Int64(0)) { $0 + $1.bytes }
            return bytes > 0 ? bytes.diskText : nil
        case .aiActivity:
            let running = ai.activity?.jobs.values.reduce(0) { $0 + $1.running } ?? 0
            return running > 0 ? "\(running)" : nil
        case .loop:
            return loop.enabled ? nil : "꺼짐"
        case .glance, .memory, .aiStorage:
            return nil
        }
    }
}

/// A symbol on a rounded square of its colour, as in System Settings: easy to find at a glance. Pale with a coloured
/// symbol normally; on the selected row the square is solid and the symbol white, so only the chosen one is strong.
struct SidebarBadge: View {
    let symbol: String
    let tint: Color
    var selected = false
    var side: CGFloat = 24
    var symbolSize: CGFloat = 12

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: symbol)
            .symbolVariant(.fill)
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(selected ? Color.white : tint)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
                .fill(selected ? tint : tint.opacity(colorScheme == .dark ? 0.30 : 0.17)))
            .accessibilityHidden(true)
    }
}
