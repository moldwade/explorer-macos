import SwiftUI
import AppKit

// MARK: - Keyboard handling shared by all views

struct ListKeys: ViewModifier {
    let state: ExplorerState
    var columns: () -> Int = { 1 }
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            // Not while renaming: taking focus back would end the rename the moment you click in the field.
            .simultaneousGesture(TapGesture().onEnded { if state.renameTarget == nil { focused = true } })
            .onAppear { focused = true }
            .onChange(of: state.current) { focused = true }
            .onChange(of: state.renameTarget) { if state.renameTarget == nil { focused = true } }
            .onKeyPress(phases: [.down, .repeat]) { p in
                guard state.renameTarget == nil else { return .ignored }
                let shift = p.modifiers.contains(.shift)
                if p.modifiers.contains(.command) { return .ignored }
                let cols = max(1, columns())
                switch p.key {
                case .upArrow: state.moveSelection(-cols, extend: shift)
                case .downArrow: state.moveSelection(cols, extend: shift)
                case .leftArrow where cols > 1: state.moveSelection(-1, extend: shift)
                case .rightArrow where cols > 1: state.moveSelection(1, extend: shift)
                case .home: state.moveSelection(-100_000, extend: shift)
                case .end: state.moveSelection(100_000, extend: shift)
                case .return: if !state.selection.isEmpty { state.open(state.selection) }
                case .space:
                    if let u = state.selection.first { state.quickLook = u } else { return .ignored }
                case .escape: state.selectNone(); state.cancelCut()
                default:
                    guard !p.modifiers.contains(.control), !p.characters.isEmpty,
                          p.characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
                    else { return .ignored }
                    state.typeSelect(p.characters)
                }
                return .handled
            }
    }
}

/// Inline rename field (Explorer renames in place).
struct RenameField: View {
    let state: ExplorerState
    var alignment: TextAlignment = .leading
    @FocusState private var focus: Bool

    var body: some View {
        @Bindable var state = state
        TextField("", text: $state.renameText)
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Theme.background)
            .overlay(Rectangle().stroke(Theme.accent, lineWidth: 1.5))
            .focused($focus)
            .onSubmit { state.commitRename() }
            .onExitCommand { state.renameTarget = nil }
            .onChange(of: focus) { if !focus { state.commitRename() } }
            .onAppear {
                focus = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let t = NSApp.keyWindow?.firstResponder as? NSTextView {
                        let base = (t.string as NSString).deletingPathExtension as NSString
                        t.setSelectedRange(NSRange(location: 0, length: base.length))
                    }
                }
            }
    }
}

/// Reports a row's frame (for drag-box selection) and hover (for right-click selection).
struct RowTracking: ViewModifier {
    let state: ExplorerState
    let url: URL
    @Binding var hover: Bool

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("content")) } action: { state.rowFrames[url] = $0 }
            .onHover { h in hover = h; state.noteHover(url, h) }
            .onDisappear { state.rowFrames[url] = nil }  // off-screen rows must not be hit by the drag box
    }
}

/// Click, double-click and drag for a file row. Turned off while the row is being renamed, so clicks
/// and drags inside the name field edit the text instead of selecting, opening or dragging the file.
struct RowGestures: ViewModifier {
    let state: ExplorerState
    let item: FileItem
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .onTapGesture {
                    let m = clickModifiers()
                    let wasOnlySelection = state.selection == [item.url]
                    let single = (NSApp.currentEvent?.clickCount ?? 1) < 2
                    state.click(item, shift: m.shift, toggle: m.toggle)
                    if single, wasOnlySelection, !m.shift, !m.toggle { state.armSlowClickRename(item.url) }
                    else { state.pendingRename = nil }
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded { state.open([item.url]) })
                .gesture(DragGesture(minimumDistance: 4).onChanged { _ in
                    guard !FileDrag.active else { return }
                    if !state.selection.contains(item.url) { state.click(item, shift: false, toggle: false) }
                    FileDrag.begin(state.selectedItems.map(\.url))
                })
        } else {
            content
        }
    }
}

/// Dropping files onto a folder in the list puts them inside it (highlighted while hovering).
struct FolderDropTarget: ViewModifier {
    let state: ExplorerState
    let item: FileItem
    @State private var targeted = false

    func body(content: Content) -> some View {
        if item.isFolder {
            content
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: 1.5).opacity(targeted ? 1 : 0))
                .dropDestination(for: URL.self) { urls, _ in
                    let others = urls.filter { $0.normalized != item.url }  // a folder dropped on itself: ignore
                    guard !others.isEmpty else { return false }
                    state.drop(others, into: item.url)
                    return true
                } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

/// Drags every selected file at once through AppKit (SwiftUI's `.draggable` carries a single item).
@MainActor
enum FileDrag {
    static var active = false

    private final class Source: NSObject, NSDraggingSource {
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : [.copy, .move, .generic]
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            MainActor.assumeIsolated { FileDrag.active = false }
        }
    }
    private static let source = Source()

    static func begin(_ urls: [URL]) {
        guard !urls.isEmpty, let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        let p = view.convert(event.locationInWindow, from: nil)
        let items = urls.enumerated().map { i, u in
            let item = NSDraggingItem(pasteboardWriter: u as NSURL)
            let offset = CGFloat(min(i, 4) * 4)
            item.setDraggingFrame(NSRect(x: p.x - 16 + offset, y: p.y - 16 - offset, width: 32, height: 32),
                                  contents: i < 5 ? NSWorkspace.shared.icon(forFile: u.path) : nil)
            return item
        }
        active = true
        view.beginDraggingSession(with: items, event: event, source: source)
    }
}

/// Rubber-band selection rectangle + gesture for the empty background of a list.
struct MarqueeLayer: View {
    let state: ExplorerState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { state.selectNone() }
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("content"))
                    .onChanged { v in
                        let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                       width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                        state.updateMarquee(r, additive: NSEvent.modifierFlags.contains(.command))
                    }
                    .onEnded { _ in state.endMarquee() })
            if let r = state.marquee {
                Rectangle().fill(Theme.accent.opacity(0.18))
                    .overlay(Rectangle().stroke(Theme.accent, lineWidth: 1))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Finder-style overlapping colour dots for a file's tags.
struct TagDots: View {
    let tags: [FinderTag]

    var body: some View {
        let colors = tags.compactMap(\.nsColor).prefix(3)
        if !colors.isEmpty {
            HStack(spacing: -4) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                    Circle().fill(Color(nsColor: c)).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 1))
                }
            }
        }
    }
}

func clickModifiers() -> (shift: Bool, toggle: Bool) {
    let f = NSEvent.modifierFlags
    return (f.contains(.shift), f.contains(.command) || f.contains(.control))
}

// MARK: - Details

struct DetailsList: View {
    let state: ExplorerState
    @State private var viewportH: CGFloat = 300

    var body: some View {
        let groups = state.groups
        VStack(spacing: 0) {
            HeaderRow(state: state)
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .top) {
                        MarqueeLayer(state: state)
                        LazyVStack(spacing: 0) {
                            ForEach(groups, id: \.title) { g in
                                if state.group != .none { GroupHeader(title: g.title, count: g.items.count) }
                                ForEach(g.items) { item in DetailRow(state: state, item: item).id(item.url) }
                            }
                        }
                    }
                    .coordinateSpace(name: "content")
                    // Fill the whole visible area so clicks/drags below the last row reach the marquee layer.
                    .frame(maxWidth: .infinity, minHeight: viewportH, alignment: .top)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportH = $0 }
                .onChange(of: state.cursor) { if let a = state.cursor, state.marquee == nil { proxy.scrollTo(a) } }
            }
            .contextMenu { FileContextMenu(state: state, sel: []) }
        }
        .background(Theme.background)
        .modifier(ListKeys(state: state))
        .dropDestination(for: URL.self) { urls, _ in state.drop(urls, into: state.current); return true }
    }
}

struct GroupHeader: View {
    let title: String, count: Int
    var body: some View {
        HStack(spacing: 8) {
            Text("\(title) (\(count))").font(.system(size: 13)).foregroundStyle(Theme.accent)
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
    }
}

private struct HeaderRow: View {
    let state: ExplorerState

    private func col(_ title: String, _ key: PartialKeyPath<FileItem>, _ width: Binding<CGFloat>,
                     trailing: Bool = false) -> some View {
        let active = state.sortOrder.first?.keyPath == key
        let asc = state.sortOrder.first?.order == .forward
        return HStack(spacing: 0) {
            Button { state.setSort(key) } label: {
                HStack(spacing: 4) {
                    if trailing { Spacer(minLength: 0) }
                    Text(title).font(.system(size: 12)).foregroundStyle(active ? Theme.accent : Theme.secondary)
                    if active { Image(systemName: asc ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.secondary) }
                    if !trailing { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 8).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(Theme.divider).frame(width: 1).padding(.vertical, 4)
                .overlay(Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                        width.wrappedValue = max(60, width.wrappedValue + v.translation.width)
                    }))
        }
        .frame(width: width.wrappedValue)
    }

    var body: some View {
        @Bindable var s = state
        HStack(spacing: 0) {
            col("Name", \FileItem.name, $s.nameW)
            col("Date modified", \FileItem.modified, $s.dateW)
            col("Type", \FileItem.kind, $s.kindW)
            col("Size", \FileItem.sizeKey, $s.sizeW, trailing: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .frame(height: 28)
        .background(Theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

private struct DetailRow: View {
    let state: ExplorerState
    let item: FileItem
    @State private var hover = false

    var body: some View {
        let selected = state.selection.contains(item.url)
        let renaming = state.renameTarget == item.url
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ItemIcon(item: item, size: 18)
                if renaming { RenameField(state: state) }
                else { Text(state.displayName(item)).lineLimit(1); TagDots(tags: item.tags) }
            }
            .padding(.horizontal, 8).frame(width: state.nameW + 1, alignment: .leading)
            Text(item.modified.formatted(date: .numeric, time: .shortened))
                .padding(.horizontal, 8).frame(width: state.dateW + 1, alignment: .leading)
            Text(item.kind).lineLimit(1)
                .padding(.horizontal, 8).frame(width: state.kindW + 1, alignment: .leading)
            Text(item.sizeText).monospacedDigit()
                .padding(.horizontal, 8).frame(width: state.sizeW + 1, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Color.primary.opacity(item.isHidden || state.isCutPending(item.url) ? 0.55 : 1))
        .padding(.leading, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Theme.selection : (hover ? Theme.hover : .clear))
            .padding(.horizontal, 4))
        .contentShape(Rectangle())
        .modifier(RowTracking(state: state, url: item.url, hover: $hover))
        .modifier(RowGestures(state: state, item: item, enabled: !renaming))
        .modifier(FolderDropTarget(state: state, item: item))
        .contextMenu { FileContextMenu(state: state, sel: selected ? state.selection : [item.url]) }
    }
}

// MARK: - Icon / list grids

struct IconsGrid: View {
    let state: ExplorerState
    @State private var width: CGFloat = 800
    @State private var viewportH: CGFloat = 300

    private var mode: ViewMode { state.viewMode }
    private var horizontal: Bool { mode == .small || mode == .list }
    private var cell: CGFloat {
        switch mode { case .extraLarge: 140; case .large: 112; case .medium: 90; case .small: 210; default: 240 }
    }
    private var columnCount: Int { max(1, Int((width - 24) / (cell + 6))) }

    var body: some View {
        let groups = state.groups
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .top) {
                    MarqueeLayer(state: state)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.title) { g in
                            if state.group != .none { GroupHeader(title: g.title, count: g.items.count) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: 6, alignment: .top)],
                                      alignment: .leading, spacing: horizontal ? 2 : 8) {
                                ForEach(g.items) { item in
                                    Cell(state: state, item: item, mode: mode).id(item.url)
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .coordinateSpace(name: "content")
                .frame(maxWidth: .infinity, minHeight: viewportH, alignment: .top)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportH = $0 }
            .onChange(of: state.cursor) { if let a = state.cursor, state.marquee == nil { proxy.scrollTo(a) } }
        }
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { width = g.size.width } })
        .background(Theme.background)
        .contextMenu { FileContextMenu(state: state, sel: []) }
        .modifier(ListKeys(state: state, columns: { columnCount }))
        .dropDestination(for: URL.self) { urls, _ in state.drop(urls, into: state.current); return true }
    }

    private struct Cell: View {
        let state: ExplorerState
        let item: FileItem
        let mode: ViewMode
        @State private var hover = false

        var body: some View {
            let selected = state.selection.contains(item.url)
            let renaming = state.renameTarget == item.url
            let horizontal = mode == .small || mode == .list
            Group {
                if horizontal {
                    HStack(spacing: 6) {
                        ItemIcon(item: item, size: 16)
                        if renaming { RenameField(state: state) } else { Text(state.displayName(item)).lineLimit(1); TagDots(tags: item.tags) }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 6).frame(height: 24)
                } else {
                    VStack(spacing: 4) {
                        ThumbIcon(item: item, size: mode.iconSize)
                        if renaming { RenameField(state: state, alignment: .center) }
                        else {
                            Text(state.displayName(item)).lineLimit(2).multilineTextAlignment(.center)
                            TagDots(tags: item.tags)
                        }
                    }.padding(6).frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 12.5))
            .opacity(item.isHidden || state.isCutPending(item.url) ? 0.55 : 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.selection : (hover ? Theme.hover : .clear)))
            .contentShape(Rectangle())
            .modifier(RowTracking(state: state, url: item.url, hover: $hover))
            .modifier(RowGestures(state: state, item: item, enabled: !renaming))
            .modifier(FolderDropTarget(state: state, item: item))
            .contextMenu { FileContextMenu(state: state, sel: selected ? state.selection : [item.url]) }
        }
    }
}
