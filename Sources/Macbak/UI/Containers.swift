import SwiftUI

// MARK: - Surfaces

/// The content surface. Opaque, so text never sits on glass: white on the light window, a lifted gray in dark.
struct CardBackground: View {
    var highlighted = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Theme.cardShape
            .fill(scheme == .light ? Color(nsColor: .textBackgroundColor) : Color.white.opacity(highlighted ? 0.1 : 0.065))
            .overlay {
                Theme.cardShape.strokeBorder(contrast == .increased ? Color(nsColor: .separatorColor) : Color.primary.opacity(scheme == .light ? 0.07 : 0.09),
                                             lineWidth: contrast == .increased ? 1 : 0.5)
            }
            // Only under the pointer: a resting shadow is a blur re-rendered on the CPU whenever anything in the card moves.
            .shadow(color: .black.opacity(scheme == .light && highlighted ? 0.1 : 0), radius: highlighted ? 10 : 0, y: highlighted ? 4 : 0)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CardBackground())
    }
}

/// The coordinate space of the detail column, where a tapped tile's frame starts its expansion.
enum DetailSpace {
    static let name = "detail"
}

/// A card that opens a screen. The whole surface is the button and lifts slightly under the pointer; a tap hands over
/// the tile's frame in `DetailSpace` so the card can grow from where it sits.
struct Tile<Content: View>: View {
    let help: String
    let action: (CGRect) -> Void
    @ViewBuilder let content: Content

    /// Updated on every scroll, so it lives outside SwiftUI state: writing it must not re-render the tile.
    private final class FrameBox {
        var frame = CGRect.zero
    }

    @State private var box = FrameBox()

    var body: some View {
        Button { action(box.frame) } label: {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(Theme.cardPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Theme.cardShape)
        }
        .buttonStyle(TileStyle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(DetailSpace.name)) } action: { [box] in box.frame = $0 }
        .help(help)
        .accessibilityHint(help)
    }
}

private struct TileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TileSurface(configuration: configuration) }
}

/// Liquid response: under the pointer the card swells a little and light runs along its rim, like the edge of glass;
/// a press squeezes it and lets it spring back.
private struct TileSurface: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(CardBackground(highlighted: hovering))
            .overlay {
                if hovering {
                    Theme.cardShape
                        .strokeBorder(LinearGradient(colors: [rim.opacity(scheme == .dark ? 0.45 : 0.14), rim.opacity(0)],
                                                     startPoint: .topLeading, endPoint: .center), lineWidth: 1)
                        .transition(.opacity)
                }
            }
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.97 : hovering ? 1.012 : 1)
            .animation(.bouncy(duration: 0.3, extraBounce: 0.15), value: configuration.isPressed)
            .animation(.smooth(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }

    private var rim: Color { scheme == .dark ? .white : .black }
}

struct CardHeader<Trailing: View>: View {
    let title: String
    let symbol: String?
    let trailing: Trailing

    init(_ title: String, symbol: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
            Text(title).font(.headline)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(_ title: String, symbol: String? = nil) {
        self.init(title, symbol: symbol) { EmptyView() }
    }
}

/// The trailing mark of a tile: a chevron in a small glass bubble.
struct OpenHint: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .floatingGlass(in: Circle())
            .accessibilityHidden(true)
    }
}


// MARK: - Layout

extension View {
    /// Centers content and stops it growing past `Theme.maxContentWidth`.
    func readableColumn() -> some View {
        frame(maxWidth: Theme.maxContentWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
    }

    /// Columns this tile spans in an `AdaptiveGrid`; more than the grid has means the whole row.
    func gridSpan(_ columns: Int) -> some View { layoutValue(key: GridSpan.self, value: columns) }
}

private struct GridSpan: LayoutValueKey {
    static let defaultValue = 1
}

/// Equal columns, as many as fit at `minimumColumnWidth` (up to `maximumColumns`). Each row is as tall as its tallest
/// tile and every tile is stretched to it, so cards line up. With `fillsRows`, the last tile of a short row takes the
/// leftover columns so no row ends in a hole; legends turn it off to keep their value column aligned.
/// - Important: The column count comes from the proposed width in a single pass. `ViewThatFits` measured every
///   candidate layout on each animation frame of live content and kept half a CPU core busy.
struct AdaptiveGrid: Layout {
    var minimumColumnWidth: CGFloat = 240
    var maximumColumns = 3
    var spacing: CGFloat = Theme.gutter
    var fillsRows = true
    /// A fixed column count; nil fits as many as `minimumColumnWidth` allows. `LiquidGrid` sets it to animate changes.
    var columns: Int?

    func fittingColumns(width: CGFloat) -> Int {
        let fitting = (width + spacing) / (minimumColumnWidth + spacing)
        // `Int(_:)` traps on infinity and NaN; an unbounded proposal (`.infinity`) fits every column.
        guard fitting.isFinite else { return maximumColumns }
        return max(1, Int(min(fitting, CGFloat(maximumColumns))))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimumColumnWidth
        let rows = arrange(subviews, width: width)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: y), proposal: ProposedViewSize(width: item.width, height: row.height))
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, x: CGFloat, width: CGFloat)] = []
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        let columns = self.columns.map { max(1, min($0, maximumColumns)) } ?? fittingColumns(width: width)
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        // Pack spans into rows first, so a short row knows its leftover before widths are set.
        var packed: [[(index: Int, span: Int)]] = [[]]
        var used = 0
        for index in subviews.indices {
            let span = min(max(subviews[index][GridSpan.self], 1), columns)
            if used + span > columns {
                packed.append([])
                used = 0
            }
            packed[packed.count - 1].append((index, span))
            used += span
        }
        return packed.filter { !$0.isEmpty }.map { items in
            let leftover = fillsRows ? columns - items.reduce(0) { $0 + $1.span } : 0
            var row = Row()
            var column = 0
            for (offset, item) in items.enumerated() {
                let span = item.span + (offset == items.count - 1 ? leftover : 0)
                let itemWidth = columnWidth * CGFloat(span) + spacing * CGFloat(span - 1)
                row.items.append((item.index, (columnWidth + spacing) * CGFloat(column), itemWidth))
                row.height = max(row.height, subviews[item.index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height)
                column += span
            }
            return row
        }
    }
}

/// An `AdaptiveGrid` whose tiles glide to their new places, with a little spring, when the window crosses a column
/// breakpoint. Between breakpoints tiles simply stretch with the window.
/// - Note: The column count is held in state and changed inside an animation, so the layout change is animated;
///   a width change alone re-lays out outside any animation.
struct LiquidGrid<Content: View>: View {
    var minimumColumnWidth: CGFloat = 240
    var maximumColumns = 3
    var spacing: CGFloat = Theme.gutter
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columns: Int?

    var body: some View {
        let grid = AdaptiveGrid(minimumColumnWidth: minimumColumnWidth, maximumColumns: maximumColumns, spacing: spacing, columns: columns)
        grid { content }
            .onGeometryChange(for: Int.self) { grid.fittingColumns(width: $0.size.width) } action: { fitting in
                guard fitting != columns else { return }
                withAnimation(columns == nil || reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.18)) { columns = fitting }
            }
    }
}

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass on macOS 26 and later, a material before it.
    /// - Important: Only for controls that float over content. Cards stay opaque: glass under text hurts legibility.
    @ViewBuilder
    func floatingGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay { shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }

    /// Glass that morphs into the glass with the same `id` in the same `GlassGroup` when one view replaces the other.
    @ViewBuilder
    func floatingGlass<S: Shape>(in shape: S, id: String, namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape).glassEffectID(id, in: namespace)
        } else {
            floatingGlass(in: shape)
        }
    }

    /// A secondary action: Liquid Glass on macOS 26 and later, bordered before.
    @ViewBuilder
    func glassAction() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// The primary action of a floating control.
    @ViewBuilder
    func prominentAction() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

extension View {
    /// A control bar floating over the bottom of scrolling content. On macOS 26 and later, `safeAreaBar` also fades and
    /// blurs the content passing underneath, so text on the glass stays legible over busy rows.
    @ViewBuilder
    func floatingBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        }
    }
}

/// Lets neighboring glass shapes sample each other and blend; glass cannot sample glass outside its container.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Window visibility

/// Reports whether the hosting window is shown: false once it closes or is minimized (and, if asked, while other windows
/// cover it), true again when it comes back.
struct WindowShownReader: NSViewRepresentable {
    @Binding var shown: Bool
    var countsCoveredAsHidden = false
    /// Report as soon as the view joins its window. Windows join before they appear, so leave this off where a false
    /// "hidden" would blank the screen; menu bar panels, created hidden at launch, need it on.
    var reportsInitialState = false

    func makeNSView(context: Context) -> WindowShownView {
        let view = WindowShownView()
        view.countsCoveredAsHidden = countsCoveredAsHidden
        view.reportsInitialState = reportsInitialState
        view.onChange = { shown = $0 }
        return view
    }

    func updateNSView(_ view: WindowShownView, context: Context) {}
}

final class WindowShownView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    var countsCoveredAsHidden = false
    var reportsInitialState = false
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let names: [Notification.Name] = [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated { self?.report(closing: closing) }
            }
        }
        if reportsInitialState { report(closing: false) }
    }

    private func report(closing: Bool) {
        guard let window else { return }
        let onScreen = !countsCoveredAsHidden || window.occlusionState.contains(.visible)
        onChange(!closing && window.isVisible && !window.isMiniaturized && onScreen)
    }
}

extension View {
    /// Live values change without animation while the window is not on screen: closed, minimized, covered, or a menu bar
    /// panel that is not open.
    /// - Important: SwiftUI keeps a hidden window's views alive. The closed menu bar panel kept animating its numbers and
    ///   bars on every sample and cost a third of a core with no window in sight.
    /// - Parameter onChange: told each time the window comes on screen or leaves it.
    func animatesOnlyWhenShown(onChange: @escaping @MainActor (Bool) -> Void = { _ in }) -> some View { modifier(ShownAnimations(onChange: onChange)) }
}

private struct ShownAnimations: ViewModifier {
    let onChange: @MainActor (Bool) -> Void
    @State private var shown = true

    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                if !shown { transaction.disablesAnimations = true }
            }
            .background(WindowShownReader(shown: $shown, countsCoveredAsHidden: true, reportsInitialState: true))
            .onChange(of: shown) { onChange(shown) }
    }
}

// MARK: - Motion

/// Cards fade and rise in order. Reduce Motion shows them in place with no movement.
struct RiseIn: ViewModifier {
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.arrivesInPlace) private var arrivesInPlace
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || arrivesInPlace ? 1 : 0)
            .offset(y: shown || arrivesInPlace || reduceMotion ? 0 : 12)
            .onAppear {
                guard !arrivesInPlace else {
                    shown = true
                    return
                }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.4).delay(Double(order) * 0.04)) { shown = true }
            }
    }
}

extension EnvironmentValues {
    /// Set on a screen growing out of a tapped tile: its cards, rings and bars are complete from the first frame, because
    /// the growth is the entrance. Rising in from transparent showed an empty screen for a moment.
    @Entry var arrivesInPlace = false
}

extension View {
    func riseIn(_ order: Int) -> some View { modifier(RiseIn(order: order)) }
}
