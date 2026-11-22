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
        case .loop: .orange
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
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: selection)
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
        // Frosted nearly all the way; clears only in the last stretch. The curve slows at the end, so that stretch still
        // lasts long enough not to snap.
        let frost = active ? 1 - ramp(t, 0.82, 1) : 0
        content
            .frame(width: active ? bounds.width : nil, height: active ? bounds.height : nil, alignment: .topLeading)
            // The window's own background style, not `windowBackgroundColor`: the window is tinted by the desktop
            // (bluish here), and the flat colour drew the growing page plain grey, which read as green beside it until
            // the backing came off at the end.
            .background { if active { Rectangle().fill(.windowBackground) } }
            .mask(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: active ? screenRadius / scale : 0, style: .continuous)
                    .frame(width: active ? bounds.width : nil, height: active ? rect.height / scale : nil)
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

/// The frost over a growing page: a nearly opaque wash of the window background (desktop tint included) with a soft
/// sheen and a lit rim.
/// - Important: Fixed colours only. Nothing here samples what is beneath it, so the pane can never take on the
///   colour of the page or the tile at any speed.
private struct FrostPane: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(.windowBackground.opacity(0.9))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0)], startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        lineWidth: 1))
    }
}

/// The sidebar: coloured badges in a fixed column, and the selection as a drop of Liquid Glass tinted with the selected
/// screen's colour that flows from row to row. Up and down arrows move the selection.
/// - Note: A custom list rather than `List`, whose system highlight is one accent-blue bar that jumps between rows and
///   fights the coloured badges.
private struct LiquidSidebar: View {
    @Binding var selection: Screen

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var drop
    @FocusState private var focused: Bool

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
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
    }

    private func row(_ screen: Screen) -> some View {
        SidebarRow(screen: screen, selected: selection == screen, drop: drop) {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.28)) { selection = screen }
        }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard let index = Self.order.firstIndex(of: selection) else { return .ignored }
        let next = min(max(index + offset, 0), Self.order.count - 1)
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.28)) { selection = Self.order[next] }
        return .handled
    }
}

/// One sidebar entry: badge, title, and — when selected — the glass drop behind them.
private struct SidebarRow: View {
    let screen: Screen
    let selected: Bool
    let drop: Namespace.ID
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SidebarBadge(symbol: screen.symbol, tint: screen.tint)
                Text(screen.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background {
                if selected {
                    SelectionDrop(tint: screen.tint)
                        .matchedGeometryEffect(id: "selection", in: drop)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(screen.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The selection: Liquid Glass with a wash of the screen's colour on macOS 26 and later, a tinted fill before.
private struct SelectionDrop: View {
    let tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if #available(macOS 26, *) {
            shape.fill(.clear).glassEffect(.regular.tint(tint.opacity(0.22)).interactive(), in: shape)
        } else {
            shape.fill(tint.opacity(0.18)).overlay(shape.strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
        }
    }
}

/// A white symbol on a rounded square of colour, as in System Settings: easy to find at a glance, and readable on the
/// selection highlight too.
struct SidebarBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .symbolVariant(.fill)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous).fill(tint.gradient))
            .accessibilityHidden(true)
    }
}
