import AppKit
import Combine
import SwiftUI

private enum ClipboardFilter: String, CaseIterable, Sendable {
    case all = "全部", text = "文字", image = "图片", file = "文件"
    func includes(_ item: ClipboardHistoryItem) -> Bool {
        switch self { case .all: true; case .text: item.isText; case .image: item.isVisualContent; case .file: item.isStoredFile }
    }
}

// The search index is rebuilt only when history changes, off the main actor.
private actor ClipboardSearchIndex {
    private var revision: UUID?
    private var entries: [(ClipboardHistoryItem, String)] = []
    func search(_ items: [ClipboardHistoryItem], revision: UUID, query: String, filter: ClipboardFilter) -> [ClipboardHistoryItem] {
        if query.isEmpty { return filter == .all ? items : items.filter { filter.includes($0) } }
        if self.revision != revision {
            var updated: [(ClipboardHistoryItem, String)] = []
            updated.reserveCapacity(items.count)
            for (offset, item) in items.enumerated() {
                if offset.isMultiple(of: 32), Task.isCancelled { return [] }
                updated.append((item, item.content.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)))
            }
            guard !Task.isCancelled else { return [] }
            entries = updated
            self.revision = revision
        }
        let key = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var result: [ClipboardHistoryItem] = []
        for (offset, entry) in entries.enumerated() {
            if offset.isMultiple(of: 32), Task.isCancelled { return [] }
            if filter.includes(entry.0), entry.1.contains(key) { result.append(entry.0) }
        }
        return result
    }
}

@MainActor
final class ClipboardBrowserState: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { search() } } }
    @Published fileprivate var filter = ClipboardFilter.all { didSet { if filter != oldValue { search() } } }
    @Published private(set) var items: [ClipboardHistoryItem] = []
    @Published private(set) var isSearching = false
    @Published var selection: UUID?
    private var snapshot: [ClipboardHistoryItem] = []
    private var revision = UUID()
    private var generation = 0
    private let index = ClipboardSearchIndex()
    private var observation: AnyCancellable?
    private var searchTask: Task<Void, Never>?
    private var lastPresented = Date.distantPast

    init(store: ClipboardHistoryStore) {
        observation = store.$items.sink { [weak self] items in
            guard let self else { return }
            self.snapshot = items
            self.revision = UUID()
            self.search()
        }
    }
    func presented() {
        if Date().timeIntervalSince(lastPresented) > 10 { selection = items.first?.id }
        lastPresented = Date()
    }
    func move(_ delta: Int) {
        guard !isSearching, !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selection } ?? 0
        selection = items[max(0, min(items.count - 1, current + delta))].id
    }
    private func apply(_ result: [ClipboardHistoryItem]) {
        items = result
        if !result.contains(where: { $0.id == selection }) { selection = result.first?.id }
        isSearching = false
    }
    private func search() {
        generation += 1
        let current = generation
        searchTask?.cancel()
        isSearching = true
        if query.isEmpty {
            apply(filter == .all ? snapshot : snapshot.filter { filter.includes($0) })
            return
        }
        let source = snapshot, revisionKey = revision, searchQuery = query, selectedFilter = filter, searchIndex = index
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(45)) } catch { return }
            let result = await searchIndex.search(source, revision: revisionKey, query: searchQuery, filter: selectedFilter)
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.apply(result)
        }
    }
    deinit { searchTask?.cancel() }
}

struct ClipboardBrowserView: View {
    @ObservedObject var model: AppModel
    let store: ClipboardHistoryStore
    let standalone: Bool
    @StateObject private var state: ClipboardBrowserState
    @State private var preview: ClipboardHistoryItem?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(model: AppModel, store: ClipboardHistoryStore, standalone: Bool, state: ClipboardBrowserState? = nil) {
        self.model = model; self.store = store; self.standalone = standalone
        _state = StateObject(wrappedValue: state ?? ClipboardBrowserState(store: store))
    }
    var body: some View {
        VStack(spacing: 0) {
            searchBar.padding(.horizontal, 14).padding(.top, standalone ? 14 : 0).padding(.bottom, 8)
            filters.padding(.horizontal, 14).padding(.bottom, 8)
            history.padding(.horizontal, 8)
            HStack(spacing: 6) {
                Text(model.message.isEmpty ? "\(state.items.count) 条" : model.message).lineLimit(1)
                Spacer(minLength: 4)
                Text("↑ ↓").font(.system(size: 10, design: .monospaced))
                Text("↵").font(.system(size: 12)).padding(.leading, 4)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { if standalone { PanelMaterial() } }
        .clipShape(RoundedRectangle(cornerRadius: standalone ? 18 : 0))
        .overlay { if standalone { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.65), lineWidth: 0.5).allowsHitTesting(false) } }
        .tint(.blue)
        .sheet(item: $preview) { item in previewView(item) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.title == (standalone ? "剪贴板" : "hui"), window.isVisible else { return }
            state.presented(); searchFocused = true
        }
        .background(KeyListener { event in
            guard preview == nil, event.window?.attachedSheet == nil else { return false }
            if let input = event.window?.firstResponder as? NSTextInputClient, input.hasMarkedText() { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 { model.onHide?(); return true }
            guard modifiers.isEmpty else { return false }
            if event.keyCode == 125 || event.keyCode == 126 { state.move(event.keyCode == 125 ? 1 : -1); return true }
            if event.keyCode == 36 {
                if !state.isSearching, let item = state.items.first(where: { $0.id == state.selection }) { model.paste(item) }
                return true
            }
            return false
        })
    }
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(searchFocused ? Color.blue : .secondary)
            TextField("搜索剪贴板", text: $state.query).textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                .accessibilityLabel("搜索剪贴板")
            if !state.query.isEmpty {
                Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("清除搜索")
            }
        }.padding(.horizontal, 10).frame(height: 32)
            .background(Color(nsColor: .textBackgroundColor).opacity(colorScheme == .dark ? 0.40 : 0.75), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(searchFocused ? .blue.opacity(0.45) : .primary.opacity(0.09), lineWidth: searchFocused ? 1 : 0.5))
    }
    private var filters: some View {
        HStack(spacing: 3) {
            ForEach(ClipboardFilter.allCases, id: \.self) { filter in
                Button { state.filter = filter } label: {
                    Text(filter.rawValue).font(.system(size: 11, weight: state.filter == filter ? .semibold : .regular))
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(state.filter == filter ? Color.primary.opacity(0.085) : .clear, in: Capsule())
                        .foregroundStyle(state.filter == filter ? Color.primary : .secondary)
                }.buttonStyle(.plain).accessibilityAddTraits(state.filter == filter ? .isSelected : [])
            }
            Spacer()
            if model.paused { Image(systemName: "pause.circle").foregroundStyle(.secondary).help("收集已暂停") }
        }
    }
    private var history: some View {
        Group {
            if state.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: state.query.isEmpty ? "square.on.square" : "magnifyingglass").font(.system(size: 24, weight: .light))
                    Text(state.query.isEmpty ? "暂无记录" : "无搜索结果").font(.system(size: 12))
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(state.items) { item in
                                ClipboardRow(item: item, selected: state.selection == item.id, store: store,
                                             onPaste: { guard !state.isSearching else { return }; state.selection = item.id; model.paste(item) },
                                             onCopy: { guard !state.isSearching else { return }; model.copy(item) },
                                             onPreview: { guard !state.isSearching else { return }; preview = item })
                                    .equatable().id(item.id)
                            }
                        }.padding(4)
                    }
                    .onChange(of: state.selection) { _, id in
                        guard let id else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .disabled(state.isSearching)
        .modifier(ContentSurface(radius: 12))
    }
    private func previewView(_ item: ClipboardHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("预览").font(.system(size: 13, weight: .semibold)); Spacer(); Button("完成") { preview = nil }.keyboardShortcut(.cancelAction) }
            ScrollView {
                if item.isVisualContent { ClipboardThumbnail(item: item, store: store, side: 300, fit: true) }
                else { Text(item.content).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack { Spacer(); Button("复制") { model.copy(item); preview = nil }.buttonStyle(.borderedProminent) }
        }.padding(16).frame(width: 340, height: 360)
    }
}

private struct ClipboardRow: View, Equatable {
    let item: ClipboardHistoryItem
    let selected: Bool
    let store: ClipboardHistoryStore
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onPreview: () -> Void
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item && lhs.selected == rhs.selected }
    var body: some View {
        HStack(spacing: 3) {
            Button(action: onPaste) {
                HStack(spacing: 10) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.isVisualContent ? (item.kind == .gif ? "动态图片" : "图片") : String(item.content.prefix(180)))
                            .font(.system(size: 12, weight: selected ? .medium : .regular)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 5) {
                            Text(item.isText ? "\(item.content.count) 字" : (item.isVisualContent ? "图片" : "文件"))
                            Text("·"); Text(item.timestamp, style: .time)
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: onPreview) { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 22, height: 30) }
                .buttonStyle(.plain).help("预览").accessibilityLabel("预览").foregroundStyle(.secondary)
            Button(action: onCopy) { Image(systemName: "doc.on.doc").frame(width: 22, height: 30) }
                .buttonStyle(.plain).help("复制").accessibilityLabel("复制").foregroundStyle(selected ? Color.blue : .secondary)
        }
        .font(.system(size: 11)).padding(.horizontal, 9).frame(height: 50)
        .background {
            RoundedRectangle(cornerRadius: 9).fill(selected ? Color.blue.opacity(colorScheme == .dark ? 0.24 : 0.105) : Color.primary.opacity(hovered ? 0.035 : 0))
        }
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 9).strokeBorder(.blue.opacity(0.23), lineWidth: 0.6) }
        }
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(.blue).frame(width: 2.5, height: 20).padding(.leading, 1) }
        }
        .onHover { hovered = $0 }
        .contextMenu { Button("复制", action: onCopy); Button("预览", action: onPreview) }
    }
    @ViewBuilder private var thumbnail: some View {
        if item.isVisualContent { ClipboardThumbnail(item: item, store: store, side: 32).clipShape(RoundedRectangle(cornerRadius: 6)) }
        else {
            Image(systemName: item.isStoredFile ? "doc" : "text.alignleft").font(.system(size: 15))
                .foregroundStyle(selected ? Color.blue : .secondary).frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
