import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Two small additions to the panel: the File Shelf (drop files on the island
// to keep them at hand) and Shortcuts buttons (your own Apple Shortcuts in
// the panel's header). Neither needs a permission.

// MARK: - File Shelf

/// Files you dropped on the island, kept until you take them out. The shelf
/// holds where they are, not copies, and remembers them across restarts.
@MainActor
@Observable
final class FileShelf {
    struct Item: Identifiable, Hashable {
        let id = UUID()
        let url: URL
        var name: String { url.lastPathComponent }
    }

    private(set) var items: [Item] = []
    static let limit = 12

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "shelf.paths") ?? []
        items = saved.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Item(url: $0) }
    }

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url.standardizedFileURL))
        let new = urls.map(\.standardizedFileURL).filter { !known.contains($0) }
        guard !new.isEmpty else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            items.append(contentsOf: new.map { Item(url: $0) })
            if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
        }
        save()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        Diag.count("shelf.add", new.count)
    }

    func remove(_ item: Item) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { items.removeAll { $0.id == item.id } }
        save()
    }

    func clear() {
        withAnimation(.easeOut(duration: 0.2)) { items.removeAll() }
        save()
    }

    /// Files moved or deleted since they were shelved drop off.
    func prune() {
        let alive = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if alive.count != items.count {
            items = alive
            save()
        }
    }

    func open(_ item: Item) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    /// AirDrop: macOS's own sheet to pick who gets them.
    func airDrop(_ selection: [Item]? = nil) {
        let urls = (selection ?? items).map(\.url)
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    /// Files dropped on the panel.
    func importDrop(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        for provider in files {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                guard let url else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.add([url]) }
                }
            }
        }
        return true
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.url.path), forKey: "shelf.paths")
    }
}

/// The shelf in the panel: one row of files, dragged out to wherever you
/// need them. Shows only when it holds something, or while a file is being
/// dragged over the panel.
struct ShelfView: View {
    let vm: NotchViewModel
    let isTargeted: Bool

    var body: some View {
        let shelf = vm.shelf
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Shelf")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if !shelf.items.isEmpty {
                    Button {
                        shelf.airDrop()
                    } label: {
                        Text("AirDrop")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                    }
                    .buttonStyle(PressStyle())
                    .help("Send everything on the shelf with AirDrop")
                    Button {
                        shelf.clear()
                    } label: {
                        Text("Clear")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                    }
                    .buttonStyle(PressStyle())
                }
            }
            if shelf.items.isEmpty {
                Text("Drop to keep it here")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(shelf.items) { item in
                            ShelfItemView(item: item, vm: vm)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isTargeted ? 0.12 : 0.06))
            if isTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isTargeted)
    }
}

/// One shelved file: its Finder icon and name. Drag it out to use it; click
/// to open it.
private struct ShelfItemView: View {
    let item: FileShelf.Item
    let vm: NotchViewModel

    private var isScript: Bool {
        ScriptLibrary.importExtensions.contains(item.url.pathExtension.lowercased())
    }

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            Text(item.name)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 52)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture { vm.shelf.open(item) }
        .help(item.name)
        .contextMenu {
            Button("Open") { vm.shelf.open(item) }
            Button("Show in Finder") { vm.shelf.reveal(item) }
            Button("AirDrop\u{2026}") { vm.shelf.airDrop([item]) }
            if isScript {
                Button("Open in Teleprompter") { vm.importScript(at: item.url) }
            }
            Divider()
            Button("Remove from Shelf", role: .destructive) { vm.shelf.remove(item) }
        }
    }
}

// MARK: - Shortcuts buttons

/// The colors a Shortcuts button can take, deep enough for white text.
enum ShortcutColor: String, CaseIterable, Codable, Identifiable {
    case orange, blue, pink, purple, green, teal, indigo, graphite

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Lighter at the top, like the tiles in the Shortcuts app.
    var top: Color {
        switch self {
        case .orange: Color(red: 0.96, green: 0.62, blue: 0.04)
        case .blue: Color(red: 0.31, green: 0.56, blue: 0.97)
        case .pink: Color(red: 0.96, green: 0.45, blue: 0.71)
        case .purple: Color(red: 0.69, green: 0.49, blue: 0.97)
        case .green: Color(red: 0.20, green: 0.83, blue: 0.60)
        case .teal: Color(red: 0.22, green: 0.74, blue: 0.97)
        case .indigo: Color(red: 0.51, green: 0.55, blue: 0.97)
        case .graphite: Color(red: 0.61, green: 0.64, blue: 0.69)
        }
    }

    var bottom: Color {
        switch self {
        case .orange: Color(red: 0.76, green: 0.25, blue: 0.05)
        case .blue: Color(red: 0.11, green: 0.31, blue: 0.85)
        case .pink: Color(red: 0.75, green: 0.09, blue: 0.36)
        case .purple: Color(red: 0.49, green: 0.13, blue: 0.81)
        case .green: Color(red: 0.02, green: 0.47, blue: 0.34)
        case .teal: Color(red: 0.05, green: 0.45, blue: 0.56)
        case .indigo: Color(red: 0.26, green: 0.22, blue: 0.79)
        case .graphite: Color(red: 0.29, green: 0.33, blue: 0.39)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

/// Up to three of your Apple Shortcuts, as buttons in the panel's header.
@MainActor
@Observable
final class ShortcutButtons {
    struct Pinned: Codable, Hashable, Identifiable {
        var name: String
        var symbol: String
        /// nil in buttons saved before colors existed; `tint` picks one.
        var color: ShortcutColor?
        var id: String { name }
        var tint: ShortcutColor { color ?? .blue }
    }

    private(set) var pinned: [Pinned]
    /// Your shortcuts, for the pickers in Settings.
    private(set) var available: [String] = []
    private(set) var running: Set<String> = []
    /// The banner when one finishes (wired in App).
    @ObservationIgnored var onResult: (@MainActor (Pinned, String?) -> Void)?

    static let maxPinned = 3

    struct SymbolGroup: Hashable {
        let name: String
        let symbols: [String]
        init(_ name: String, _ symbols: [String]) {
            self.name = name
            self.symbols = symbols
        }
    }

    /// Glyphs to pick from, in groups.
    static let symbolGroups: [SymbolGroup] = [
        SymbolGroup("Everyday", ["bolt.fill", "sparkles", "wand.and.stars", "star.fill", "heart.fill", "flame.fill", "leaf.fill", "drop.fill"]),
        SymbolGroup("Home", ["house.fill", "lightbulb.fill", "lamp.desk.fill", "fan.fill", "powerplug.fill", "tv.fill", "speaker.wave.2.fill", "headphones"]),
        SymbolGroup("Media", ["play.fill", "music.note", "mic.fill", "camera.fill", "video.fill", "photo.fill", "film.fill", "gamecontroller.fill"]),
        SymbolGroup("Files", ["doc.fill", "folder.fill", "tray.full.fill", "paperclip", "link", "square.and.arrow.up.fill", "printer.fill", "scissors"]),
        SymbolGroup("People and Time", ["envelope.fill", "message.fill", "phone.fill", "person.fill", "person.2.fill", "calendar", "clock.fill", "timer"]),
        SymbolGroup("Day and Travel", ["alarm.fill", "moon.fill", "sun.max.fill", "cloud.sun.fill", "umbrella.fill", "car.fill", "airplane", "figure.walk"]),
        SymbolGroup("Life", ["cup.and.saucer.fill", "fork.knife", "cart.fill", "creditcard.fill", "gift.fill", "book.fill", "graduationcap.fill", "briefcase.fill"]),
        SymbolGroup("Mac", ["terminal.fill", "keyboard.fill", "desktopcomputer", "laptopcomputer", "lock.fill", "key.fill", "wifi", "globe"]),
    ]
    static let symbols = symbolGroups.flatMap { $0.symbols }

    /// A first glyph from the shortcut's name ("Desk Lights" gets the bulb),
    /// in English or Italian. You can change it in Settings.
    static func guessSymbol(for name: String) -> String {
        let words = name.lowercased()
        let guesses: [([String], String)] = [
            (["light", "lamp", "luce", "luci", "lampada"], "lightbulb.fill"),
            (["record", "video", "camera", "meeting", "zoom", "facetime", "registra", "riunione"], "video.fill"),
            (["call", "phone", "chiama", "telefono"], "phone.fill"),
            (["music", "spotify", "playlist", "song", "musica", "canzone"], "music.note"),
            (["play", "start", "avvia"], "play.fill"),
            (["focus", "sleep", "night", "bed", "notte", "dormi"], "moon.fill"),
            (["morning", "sun", "mattina", "giorno"], "sun.max.fill"),
            (["home", "house", "casa"], "house.fill"),
            (["mail", "email"], "envelope.fill"),
            (["message", "text", "sms", "whatsapp", "messaggio"], "message.fill"),
            (["timer", "pomodoro"], "timer"),
            (["alarm", "wake", "sveglia"], "alarm.fill"),
            (["note", "doc", "write", "journal", "nota", "scrivi"], "doc.fill"),
            (["file", "folder", "cartella"], "folder.fill"),
            (["screenshot", "photo", "image", "picture", "foto"], "photo.fill"),
            (["weather", "rain", "meteo", "pioggia"], "cloud.sun.fill"),
            (["car", "drive", "auto", "macchina"], "car.fill"),
            (["flight", "travel", "trip", "viaggio", "volo"], "airplane"),
            (["coffee", "break", "caff", "pausa"], "cup.and.saucer.fill"),
            (["food", "lunch", "dinner", "recipe", "pranzo", "cena", "ricetta"], "fork.knife"),
            (["shop", "buy", "grocery", "spesa", "compra"], "cart.fill"),
            (["walk", "run", "workout", "gym", "palestra", "corsa"], "figure.walk"),
            (["work", "office", "lavoro", "ufficio"], "briefcase.fill"),
            (["study", "learn", "school", "studio", "lezione"], "book.fill"),
            (["calendar", "agenda", "calendario"], "calendar"),
            (["lock", "blocca"], "lock.fill"),
            (["wifi", "network", "rete"], "wifi"),
            (["share", "airdrop", "condividi"], "square.and.arrow.up.fill"),
            (["print", "stampa"], "printer.fill"),
            (["game", "gioco"], "gamecontroller.fill"),
            (["terminal", "script", "code", "dev"], "terminal.fill"),
            (["translate", "language", "traduci", "web"], "globe"),
        ]
        for (keys, symbol) in guesses where keys.contains(where: { words.contains($0) }) {
            return symbol
        }
        return "bolt.fill"
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "shortcutButtons"),
           let saved = try? JSONDecoder().decode([Pinned].self, from: data) {
            var list = Array(saved.prefix(Self.maxPinned))
            // Buttons from before colors existed each get their own.
            for index in list.indices where list[index].color == nil && !list[index].name.isEmpty {
                let taken = Set(list.compactMap(\.color))
                list[index].color = ShortcutColor.allCases.first { !taken.contains($0) } ?? .blue
            }
            pinned = list
        } else {
            pinned = []
        }
    }

    /// Slot 0, 1 or 2: a nil name empties it. A newly chosen shortcut gets a
    /// glyph from its name and a color the other buttons aren't using.
    func set(slot: Int, name: String?) {
        var list = pinned
        while list.count <= slot { list.append(Pinned(name: "", symbol: "bolt.fill")) }
        let new = name ?? ""
        if new != list[slot].name {
            list[slot].name = new
            if !new.isEmpty {
                list[slot].symbol = Self.guessSymbol(for: new)
                let taken = Set(list.enumerated().filter { $0.offset != slot && !$0.element.name.isEmpty }.compactMap { $0.element.color })
                list[slot].color = ShortcutColor.allCases.first { !taken.contains($0) } ?? .blue
            }
        }
        pinned = list
        save()
    }

    func set(slot: Int, symbol: String) {
        guard slot < pinned.count else { return }
        pinned[slot].symbol = symbol
        save()
    }

    func set(slot: Int, color: ShortcutColor) {
        guard slot < pinned.count else { return }
        pinned[slot].color = color
        save()
    }

    func slot(_ index: Int) -> Pinned? {
        index < pinned.count && !pinned[index].name.isEmpty ? pinned[index] : nil
    }

    /// The buttons that show in the panel.
    var buttons: [Pinned] { pinned.filter { !$0.name.isEmpty } }

    /// Reads your shortcuts' names (`shortcuts list`), off the main thread.
    func loadAvailable() {
        Task.detached {
            let names = Self.runTool(["list"]).output
                .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            await MainActor.run { self.available = names }
        }
    }

    func run(_ shortcut: Pinned) {
        guard !running.contains(shortcut.name) else { return }
        running.insert(shortcut.name)
        Diag.count("shortcuts.run")
        let name = shortcut.name
        Task.detached {
            let result = Self.runTool(["run", name])
            await MainActor.run {
                self.running.remove(name)
                self.onResult?(shortcut, result.status == 0 ? nil : (result.error.isEmpty ? "It stopped with an error." : result.error))
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pinned) {
            UserDefaults.standard.set(data, forKey: "shortcutButtons")
        }
    }

    nonisolated private static func runTool(_ arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        guard (try? process.run()) != nil else { return (-1, "", "Shortcuts isn't available.") }
        let output = out.fileHandleForReading.readDataToEndOfFile()   // read before waiting
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: output, encoding: .utf8) ?? "",
                String(data: error, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
