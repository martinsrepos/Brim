import AppKit
import SwiftUI

// The Shortcuts buttons as cards in Settings, the glyph and color picker
// they open, their buttons in the panel, and the centered glyph every icon
// tile in Settings uses.

// MARK: - Centered glyphs

/// An SF Symbol centered on the ink it actually paints.
///
/// A symbol's box includes side bearings, and many glyphs have more room on
/// one side than the other, so a symbol centered by its box sits a little
/// off (most of them to the left). This trims each glyph to its painted
/// pixels once, then centers that. Every glyph is drawn at the same point
/// size, which keeps the optical balance Apple designed into them; one wider
/// or taller than `maxSide` shrinks to fit.
struct CenteredSymbol: View {
    let name: String
    let pointSize: CGFloat
    let maxSide: CGFloat
    var weight: NSFont.Weight = .semibold

    var body: some View {
        if let ink = SymbolInk.image(name, weight: weight) {
            let natural = pointSize / SymbolInk.renderSize
            let width = ink.size.width * natural
            let height = ink.size.height * natural
            let fit = min(1, maxSide / max(width, height))
            Image(nsImage: ink)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: width * fit, height: height * fit)
        } else {
            Image(systemName: name)
                .font(.system(size: pointSize * 0.85, weight: .semibold))
        }
    }
}

/// Symbols trimmed to their ink, made once and kept.
@MainActor
enum SymbolInk {
    /// The point size glyphs are traced at; `CenteredSymbol` scales from it.
    static let renderSize: CGFloat = 64
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func image(_ name: String, weight: NSFont.Weight) -> NSImage? {
        let key = "\(name)|\(weight.rawValue)"
        if let hit = cache[key] { return hit }
        if missing.contains(key) { return nil }
        guard let made = trace(name, weight: weight) else {
            missing.insert(key)
            return nil
        }
        cache[key] = made
        return made
    }

    private static func trace(_ name: String, weight: NSFont.Weight) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: renderSize, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = symbol.size
        let scale: CGFloat = 2
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: scale, y: scale)
        symbol.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let full = context.makeImage(), let data = context.data else { return nil }
        // The first row in memory is the top of the image, like `cropping(to:)`.
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where bytes[row + x * 4 + 3] > 10 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let ink = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = full.cropping(to: ink) else { return nil }
        let image = NSImage(cgImage: cropped, size: NSSize(width: ink.width / scale, height: ink.height / scale))
        image.isTemplate = true
        return image
    }
}

// MARK: - Cards in Settings

/// One Shortcuts button in Settings. Empty, it's a grey card that lists your
/// shortcuts; with a shortcut it takes a color and a glyph, and the glyph
/// opens the picker.
struct ShortcutCard: View {
    let slot: Int
    let shortcuts: ShortcutButtons
    let state: SettingsState

    private static let height: CGFloat = 112
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        if let current = shortcuts.slot(slot) {
            assigned(current)
        } else {
            empty
        }
    }

    private func assigned(_ current: ShortcutButtons.Pinned) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                Button {
                    state.glyphSlot = slot
                } label: {
                    CenteredSymbol(name: current.symbol, pointSize: 17, maxSide: 20)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.white.opacity(0.22)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle(pressedScale: 0.9))
                .help("Change the icon and color")
                .accessibilityLabel("Change the icon for \(current.name)")
                .popover(isPresented: Binding(get: { state.glyphSlot == slot },
                                              set: { if !$0 { state.glyphSlot = nil } }),
                         arrowEdge: .bottom) {
                    GlyphPicker(slot: slot, shortcuts: shortcuts)
                }

                Spacer(minLength: 4)

                Menu {
                    menuItems(current)
                } label: {
                    CenteredSymbol(name: "ellipsis", pointSize: 13, maxSide: 13, weight: .bold)
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.black.opacity(0.18)))
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More for \(current.name)")
            }
            Spacer(minLength: 6)
            Text(current.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(isMissing(current) ? "Not in Shortcuts" : "Shortcut")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .background(shape.fill(current.tint.gradient))
        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .contextMenu { menuItems(current) }
    }

    private var empty: some View {
        Menu {
            shortcutChoices
        } label: {
            VStack(spacing: 8) {
                CenteredSymbol(name: "plus", pointSize: 15, maxSide: 15)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
                Text("Choose a Shortcut")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
            .background(shape.fill(Color.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Choose a shortcut for button \(slot + 1)")
    }

    @ViewBuilder
    private func menuItems(_ current: ShortcutButtons.Pinned) -> some View {
        Button("Run Now") { shortcuts.run(current) }
        Menu("Change Shortcut") { shortcutChoices }
        Button("Change Icon and Color") { state.glyphSlot = slot }
        Divider()
        Button("Remove", role: .destructive) { shortcuts.set(slot: slot, name: nil) }
    }

    @ViewBuilder
    private var shortcutChoices: some View {
        if shortcuts.available.isEmpty {
            Text("No Shortcuts Found")
        }
        ForEach(shortcuts.available, id: \.self) { name in
            Button(name) { shortcuts.set(slot: slot, name: name) }
        }
        Divider()
        Button("Open Shortcuts") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
        }
    }

    /// Renamed or deleted in the Shortcuts app since it was pinned.
    private func isMissing(_ current: ShortcutButtons.Pinned) -> Bool {
        !shortcuts.available.isEmpty && !shortcuts.available.contains(current.name)
    }
}

/// The picker a card's glyph opens: a row of colors, then the glyphs in
/// their groups. It stays open, so you can pick both; click away to close.
private struct GlyphPicker: View {
    let slot: Int
    let shortcuts: ShortcutButtons

    private static let cell: CGFloat = 34
    private static let spacing: CGFloat = 4

    var body: some View {
        let current = shortcuts.slot(slot)
        let tint = current?.tint ?? .blue
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(ShortcutColor.allCases) { color in
                    Button {
                        shortcuts.set(slot: slot, color: color)
                    } label: {
                        Circle()
                            .fill(color.gradient)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                            .padding(3)
                            .overlay(Circle().strokeBorder(color == tint ? Color.primary : Color.clear, lineWidth: 2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(color.title)
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(color == tint ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ShortcutButtons.symbolGroups, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cell), spacing: Self.spacing), count: 8),
                                      spacing: Self.spacing) {
                                ForEach(group.symbols, id: \.self) { symbol in
                                    glyphButton(symbol, selected: symbol == current?.symbol, tint: tint)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 300)
        }
        .padding(12)
        .frame(width: Self.cell * 8 + Self.spacing * 7 + 24)
        // No keyboard focus ring: it landed on the first color and looked
        // like a second selection.
        .focusEffectDisabled()
    }

    private func glyphButton(_ symbol: String, selected: Bool, tint: ShortcutColor) -> some View {
        Button {
            shortcuts.set(slot: slot, symbol: symbol)
        } label: {
            CenteredSymbol(name: symbol, pointSize: 14, maxSide: 18)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: Self.cell, height: 32)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.gradient)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(symbol)
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - In the panel

/// A Shortcuts button in the panel's header, in its card's color.
struct ShortcutHeaderButton: View {
    let shortcut: ShortcutButtons.Pinned
    let isRunning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CenteredSymbol(name: isRunning ? "hourglass" : shortcut.symbol, pointSize: 12, maxSide: 14)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(shortcut.tint.gradient))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(pressedScale: 0.88))
        .accessibilityLabel(shortcut.name)
        .help(shortcut.name)
    }
}
