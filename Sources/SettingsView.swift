import AppKit
import Combine
import Observation
import ServiceManagement
import SwiftUI

/// The settings window's panes, listed in the sidebar like System Settings.
enum SettingsPane: String, CaseIterable, Identifiable {
    // General first and About last, the rest in alphabetical order.
    case general, appearance, devices, activities, notifications, permissions, controls, teleprompter, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .activities: return "Live Activities"
        case .notifications: return "Notifications"
        case .permissions: return "Permissions"
        case .teleprompter: return "Teleprompter"
        case .controls: return "Sound"
        case .devices: return "Devices"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Where the island shows and when Brim starts."
        case .appearance: return "The glass, and the size of the pill and the panel."
        case .activities: return "What the pill shows while something is going on."
        case .notifications: return "How your Mac's notifications appear in the island."
        case .permissions: return "What Brim may use on this Mac, and why."
        case .teleprompter: return "Your script under the camera, for calls and recordings."
        case .controls: return "Banners when the volume or the microphone changes."
        case .devices: return "Your monitor's brightness, and Logitech keyboards and mice."
        case .about: return "Version and updates, and a report of what Brim has been doing."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "circle.lefthalf.filled"
        case .activities: return "rectangle.topthird.inset.filled"
        case .notifications: return "bell.badge.fill"
        case .permissions: return "hand.raised.fill"
        case .teleprompter: return "text.alignleft"
        case .controls: return "speaker.wave.3.fill"
        case .devices: return "display"
        case .about: return "info"
        }
    }

    var color: Color {
        switch self {
        // System Settings' own colours for the same kinds of pane.
        case .general: return .gray
        case .appearance: return SettingsIcon.black
        case .activities: return .purple
        case .notifications: return .red
        case .permissions: return .blue
        case .teleprompter: return .orange
        case .controls: return .red
        case .devices: return .blue
        case .about: return .blue
        }
    }
}

/// A white glyph on a coloured rounded square, the way System Settings
/// marks its panes and rows.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    /// The near-black Apple uses for Appearance, Lock Screen and the Dock.
    static let black = Color(white: 0.16)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        ZStack {
            // Lighter at the top, like System Settings' tiles.
            shape.fill(color.gradient)
            // A hairline edge catching the light.
            shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
            // Centered on the ink it paints, at one point size so glyphs
            // keep Apple's optical balance; wide ones shrink to fit.
            CenteredSymbol(name: symbol, pointSize: size * 0.6, maxSide: size * 0.72)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        // A soft shadow lifts the tile off the row, so it stands out on the
        // blue of a selected row too.
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: size * 0.03 + 0.4, y: 0.5)
        .accessibilityHidden(true)
    }
}

/// A row title with its glyph.
private struct RowLabel: View {
    let title: String
    let symbol: String
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        HStack(spacing: 8) {
            SettingsIcon(symbol: symbol, color: color)
            Text(title)
        }
    }
}

/// What the settings window remembers while it's open.
@MainActor
@Observable
final class SettingsState {
    var creatingReport = false
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var permissions: [PermissionItem] = []
    /// Redraws a setting kept outside this window's state.
    var refreshTick = 0
    /// The Shortcuts button whose glyph grid is open.
    var glyphSlot: Int?

    /// Read again when the pane shows and when you come back from System
    /// Settings.
    func refreshPermissions() {
        permissions = Permissions.current()
    }
}

/// Brim's settings, laid out like System Settings: panes in a sidebar, each a
/// grouped form.
///
/// Bindings are written out by hand instead of using `@Bindable`, for the same
/// reason as `NotchUIState`: it keeps Brim buildable with the Command Line Tools.
struct SettingsView: View {
    let vm: NotchViewModel
    /// The window's own state. Not `@State`: that's a macro whose plugin the
    /// Command Line Tools don't include, so it lives in an `@Observable`
    /// object the window controller keeps.
    let state: SettingsState
    @AppStorage("settingsPane") private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsPane?>(get: { pane }, set: { if let new = $0 { pane = new } })) {
                ForEach(SettingsPane.allCases) { item in
                    HStack(spacing: 8) {
                        SettingsIcon(symbol: item.symbol, color: item.color)
                        Text(item.title)
                    }
                    .padding(.vertical, 1)
                    // Like Software Update in System Settings.
                    .badge(item == .about && Updater.shared.hasUpdate ? 1 : 0)
                    .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form {
                Section {
                    header(for: pane)
                }
                content(for: pane)
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
            .id(pane)   // each pane starts scrolled to the top
        }
        .frame(minWidth: 720, idealWidth: 740, minHeight: 540, idealHeight: 600)
        .onDisappear { vm.isPreviewingExpanded = false }
    }

    /// The card at the top of each pane, like the one in System Settings.
    private func header(for pane: SettingsPane) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: pane.symbol, color: pane.color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title)
                    .font(.headline)
                Text(pane.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func content(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: general
        case .appearance: appearance
        case .activities: activities
        case .notifications: notifications
        case .permissions: permissions
        case .teleprompter: teleprompter
        case .controls: controls
        case .devices: devices
        case .about: about
        }
    }

    // MARK: - General

    @ViewBuilder
    private var general: some View {
        Section {
            Picker("Show On", selection: Binding(get: { vm.displayChoice }, set: { vm.setDisplayChoice($0) })) {
                ForEach(NotchViewModel.DisplayChoice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
        } header: {
            Text("Displays")
        } footer: {
            footnote("With all displays, each one has its own island and the one you hover opens.")
        }

        Section {
            Toggle(isOn: Binding(get: { vm.showOnLockScreen }, set: { vm.setShowOnLockScreen($0) })) {
                RowLabel("Show on Lock Screen", symbol: "lock.fill", color: SettingsIcon.black)
            }
            Toggle(isOn: Binding(get: { vm.hideIdleWithoutNotch }, set: { vm.setHideIdleWithoutNotch($0) })) {
                RowLabel("Hide When Idle", symbol: "eye.slash.fill", color: .gray)
            }
            Toggle(isOn: Binding(get: { state.launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                RowLabel("Launch at Login", symbol: "power", color: .gray)
            }
        } header: {
            Text("Behavior")
        } footer: {
            footnote("Hide When Idle applies to the floating island: the pill goes away when nothing is happening and comes back for activities and banners.")
        }

        Section {
            HStack(spacing: 12) {
                ForEach(0..<ShortcutButtons.maxPinned, id: \.self) { slot in
                    ShortcutCard(slot: slot, shortcuts: vm.shortcuts, state: state)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            Text("Shortcut Buttons")
        } footer: {
            footnote("Up to three of your Apple Shortcuts, as buttons in the panel's header. Click a card's icon to change it and its color; the \u{2026} button has the rest. Make shortcuts in the Shortcuts app.")
        }
        .onAppear { vm.shortcuts.loadAvailable() }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            appLog.error("Launch at Login: \(error.localizedDescription, privacy: .public)")
        }
        state.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearance: some View {
        Section {
            // One look: dark Liquid Glass, from solid black (like Dynamic
            // Island) to clear glass.
            LabeledContent("Transparency") {
                HStack(spacing: 8) {
                    Text("Black").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { vm.glassTransparency }, set: { vm.setGlassTransparency($0) }),
                           in: 0...1)
                        .frame(width: 210)
                    Text("Clear").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Glass")
        }

        Section {
            Picker("Style", selection: Binding(get: { vm.shapeStyle }, set: { vm.setShapeStyle($0) })) {
                ForEach(NotchViewModel.ShapeStyle.allCases, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Shape")
        } footer: {
            footnote("Automatic draws a notch on a MacBook's notch and a floating island on other displays. Notch hangs from the top edge on any display; Floating Island floats below the top edge (on a MacBook, just under the notch).")
        }

        Section {
            sizeSlider("Width",
                       value: Binding(get: { vm.pillSize.width },
                                      set: { vm.setPillSize(CGSize(width: $0, height: vm.pillSize.height)) }),
                       in: NotchViewModel.pillWidthRange)
            sizeSlider("Height",
                       value: Binding(get: { vm.pillSize.height },
                                      set: { vm.setPillSize(CGSize(width: vm.pillSize.width, height: $0)) }),
                       in: NotchViewModel.pillHeightRange)
            sizeSlider("Distance from Top",
                       value: Binding(get: { vm.islandOffset }, set: { vm.setIslandOffset($0) }),
                       in: NotchViewModel.islandOffsetRange)
            sizeSlider("Notch Wings",
                       value: Binding(get: { vm.wingWidth }, set: { vm.setWingWidth($0) }),
                       in: vm.wingWidthRange)
        } header: {
            Text("Pill")
        } footer: {
            if vm.hasNotch && !vm.isIsland {
                footnote("On this MacBook the notch keeps the real size of the camera housing, and nothing is drawn under it. Notch Wings sets how far the notch reaches out on each side of the camera, for the artwork, timers and calls; Width and Height apply to the floating island and to screens without a notch.")
            } else if !vm.isIsland {
                footnote("Notch Wings sets how far the notch reaches out on each side for activities. Distance from Top applies to the floating island only; the notch always touches the top edge.")
            } else {
                footnote("Notch Wings applies to the notch style only.")
            }
        }

        Section {
            sizeSlider("Width",
                       value: Binding(get: { vm.panelSize.width },
                                      set: { vm.setPanelSize(CGSize(width: $0, height: vm.panelSize.height)) }),
                       in: NotchViewModel.panelWidthRange)
            sizeSlider("Height",
                       value: Binding(get: { vm.panelSize.height },
                                      set: { vm.setPanelSize(CGSize(width: vm.panelSize.width, height: $0)) }),
                       in: NotchViewModel.panelHeightRange)
            Toggle("Keep Open While Adjusting",
                   isOn: Binding(get: { vm.isPreviewingExpanded }, set: { vm.isPreviewingExpanded = $0 }))
        } header: {
            Text("Expanded Panel")
        } footer: {
            // Like the buttons at the bottom of a System Settings pane: on
            // the window, not in a box.
            VStack(alignment: .leading, spacing: 14) {
                footnote("Banners scale with the panel's width.")
                HStack {
                    Spacer()
                    Button("Restore Defaults") { vm.resetSizes() }
                        .help("Puts the pill, the notch wings, the panel and the distance from the top back to their original sizes")
                }
            }
        }
    }

    /// A plain slider (no tick marks), snapping to whole even points.
    private func sizeSlider(_ title: String, value: Binding<CGFloat>, in range: ClosedRange<CGFloat>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value.wrappedValue },
                                      set: { value.wrappedValue = (($0 / 2).rounded() * 2).clamped(to: range) }),
                       in: range)
                    .frame(width: 210)
                Text("\(Int(value.wrappedValue)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    // MARK: - Live Activities

    @ViewBuilder
    private var activities: some View {
        Section {
            Toggle(isOn: Binding(get: { vm.showClock }, set: { vm.setShowClock($0) })) {
                RowLabel("Clock When Idle", symbol: "clock.fill", color: .indigo)
            }
            Toggle(isOn: Binding(get: { vm.showWeather }, set: { vm.setShowWeather($0) })) {
                RowLabel("Weather Next to the Clock", symbol: "cloud.sun.fill", color: .cyan)
            }
            if vm.showWeather {
                TextField("City", text: Binding(get: { vm.weather.query }, set: { vm.weather.setQuery($0) }),
                          prompt: Text("Search for a city"))
                    .onSubmit { vm.weather.chooseFirstMatch() }
                // Matching cities: pick one.
                ForEach(vm.weather.results) { place in
                    Button {
                        vm.weather.choose(place)
                    } label: {
                        HStack {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(.secondary)
                            Text(place.label)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                LabeledContent("Now") {
                    Text(vm.weather.status)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Toggle(isOn: Binding(get: { vm.showPrivacyDots }, set: { vm.setShowPrivacyDots($0) })) {
                RowLabel("Camera and Microphone Dots", symbol: "hand.raised.fill", color: .blue)
            }
        } header: {
            Text("In the Pill")
        } footer: {
            footnote("Weather comes from Open-Meteo for the city you choose.")
        }

        Section {
            Toggle(isOn: Binding(get: { vm.showCalendar }, set: { vm.setShowCalendar($0) })) {
                RowLabel("Upcoming Meetings", symbol: "calendar", color: .red)
            }
            Toggle(isOn: Binding(get: { vm.showReminders }, set: { vm.setShowReminders($0) })) {
                RowLabel("Reminders Due Soon", symbol: "checklist", color: .orange)
            }
            Toggle(isOn: Binding(get: { vm.showCalls }, set: { vm.setShowCalls($0) })) {
                RowLabel("Calls", symbol: "phone.fill", color: .green)
            }
            Toggle(isOn: Binding(get: { vm.showDownloads }, set: { vm.setShowDownloads($0) })) {
                RowLabel("Downloads and AirDrop", symbol: "arrow.down", color: .blue)
            }
        } header: {
            Text("Activities")
        } footer: {
            footnote("Meetings show 15 minutes before they start, with a Join button for Zoom, Meet, Teams and FaceTime links. Reminders with a time show 15 minutes before they're due. Calls show while FaceTime, Zoom, Teams, Webex or Skype is on a call, with a mute button.")
        }

        Section {
            Picker(selection: Binding(get: { vm.timerSound }, set: { vm.setTimerSound($0) })) {
                ForEach(Tones.all, id: \.self) { Text($0).tag($0) }
            } label: {
                RowLabel("Timer Ends", symbol: "timer", color: .orange)
            }
        } header: {
            Text("Timers")
        } footer: {
            footnote("Picking a tone plays it.")
        }
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notifications: some View {
        Section {
            Toggle(isOn: Binding(get: { vm.respectFocus }, set: { vm.setRespectFocus($0) })) {
                RowLabel("Respect Focus", symbol: "moon.fill", color: .indigo)
            }
            Picker(selection: Binding(get: { vm.notificationSound }, set: { vm.setNotificationSound($0) })) {
                Text("None").tag("")
                Divider()
                ForEach(Tones.all, id: \.self) { Text($0).tag($0) }
            } label: {
                RowLabel("Banner Sound", symbol: "speaker.wave.3.fill", color: .red)
            }
        } header: {
            Text("Banners")
        } footer: {
            footnote("With Respect Focus, apps a Focus silences go to the list without a banner. macOS also plays each app's own sound; to hear only Brim's, turn off \u{201C}Play sound for notification\u{201D} for that app in System Settings > Notifications. Showing your Mac's notifications at all is switched on and off from the Brim menu in the menu bar.")
        }
    }

    // MARK: - Teleprompter

    @ViewBuilder
    private var teleprompter: some View {
        let prompter = vm.prompter
        Section {
            valueSlider("Text Size", value: Binding(get: { prompter.fontSize }, set: { prompter.setFontSize($0.rounded()) }),
                        in: Prompter.fontSizeRange, unit: "pt")
            valueSlider("Width", value: Binding(get: { prompter.width }, set: { prompter.setWidth(($0 / 2).rounded() * 2) }),
                        in: Prompter.widthRange, unit: "pt")
            valueSlider("Height", value: Binding(get: { prompter.height }, set: { prompter.setHeight(($0 / 2).rounded() * 2) }),
                        in: Prompter.heightRange, unit: "pt")
            valueSlider("Speed", value: Binding(get: { prompter.wordsPerMinute }, set: { prompter.setSpeed($0) }),
                        in: Prompter.speedRange, unit: "wpm")
        } header: {
            Text("Prompter")
        } footer: {
            footnote("Speed is for the steady scroll, in words a minute; about 130 is a calm speaking pace. You can also change it while reading. With Follow My Voice it's only used to estimate the time left.")
        }

        Section {
            Toggle(isOn: Binding(get: { prompter.followsVoice }, set: { prompter.setFollowsVoice($0) })) {
                RowLabel("Follow My Voice", symbol: "waveform", color: .orange)
            }
        } header: {
            Text("Scrolling")
        } footer: {
            footnote("The script scrolls as you speak and waits when you stop, in the language set in the script's editor (English or Italian). It listens with Apple's speech recognition on this Mac only: nothing is recorded or sent anywhere. The first time, macOS asks for the Microphone and Speech Recognition. It keeps up if a word is misheard or you skip a few; jumping far ahead or back takes a few words to catch. On calls, wear headphones, so the other person's voice doesn't move your script. Turned off, or for a language this Mac can't recognize offline, it scrolls at the steady speed above.")
        }

        Section {
            Toggle(isOn: Binding(get: { prompter.countsDown }, set: { prompter.setCountsDown($0) })) {
                RowLabel("Count Down Before a Steady Scroll", symbol: "timer", color: .orange)
            }
            Toggle(isOn: Binding(get: { prompter.hidesFromSharing }, set: { prompter.setHidesFromSharing($0) })) {
                RowLabel("Hide from Screen Sharing", symbol: "eye.slash.fill", color: .blue)
            }
            Toggle(isOn: Binding(get: { prompter.mirrored }, set: { prompter.setMirrored($0) })) {
                RowLabel("Mirror Text", symbol: "arrow.left.and.right", color: .gray)
            }
        } header: {
            Text("Behavior")
        } footer: {
            footnote("While the prompter is open, banners wait until you close it, hovering doesn't open the panel and the Mac stays awake. Hide from Screen Sharing asks macOS to leave the island out of screen shares and recordings, but apps that use macOS's current capture (FaceTime, QuickTime and others) show it anyway. To keep your script private, share a window or an app instead of the entire screen. Mirror Text is for teleprompter glass in front of a camera.")
        }

        Section {
            ForEach(PrompterHotKeys.labels.indices, id: \.self) { index in
                LabeledContent(PrompterHotKeys.labels[index].1) {
                    Text(PrompterHotKeys.labels[index].0).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Shortcuts")
        } footer: {
            footnote("Set them on MX Creative Console buttons in Logi Options+ (a keyboard shortcut action). For the dial, give its two directions the forward and back shortcuts: each click glides half a line. Over the prompter, the scroll wheel or trackpad moves the script by hand too. Links work too: brim://prompter?action=toggle, faster, slower, forward, back or stop.")
        }
    }

    /// A slider with its value, without tick marks.
    private func valueSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                             unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .frame(width: 210)
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissions: some View {
        Section {
            ForEach(state.permissions) { item in
                LabeledContent {
                    HStack(spacing: 8) {
                        Label(item.status.label, systemImage: item.status.symbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(item.status.color)
                            .font(.callout)
                        if item.status.needsAttention, let url = item.settingsURL {
                            Button("Open\u{2026}") { NSWorkspace.shared.open(url) }
                                .controlSize(.small)
                                .help("Opens this page of System Settings")
                        }
                    }
                    .fixedSize()
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        SettingsIcon(symbol: item.symbol, color: item.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.purpose)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } header: {
            Text("Privacy & Security")
        } footer: {
            footnote("Brim asks for each one only when a feature first needs it, and works without any of them: that feature just stays off. Change them in System Settings > Privacy & Security; this list updates when you come back.")
        }
        .onAppear { state.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshPermissions()
        }
    }

    // MARK: - Sound

    @ViewBuilder
    private var controls: some View {
        Section {
            Toggle(isOn: Binding(get: { vm.showVolume }, set: { vm.setShowVolume($0) })) {
                RowLabel("Volume", symbol: "speaker.wave.3.fill", color: .red)
            }
            Toggle(isOn: Binding(get: { vm.showMicrophoneMute }, set: { vm.setShowMicrophoneMute($0) })) {
                RowLabel("Microphone Mute", symbol: "mic.slash.fill", color: .orange)
            }
        } header: {
            Text("Sound")
        } footer: {
            footnote("A banner when the volume changes or the microphone is muted or back on, whatever did it. macOS still shows its own volume pop-up too.")
        }
    }

    // MARK: - Devices

    @ViewBuilder
    private var devices: some View {
        if PowerMonitor.hasBattery {
            Section {
                Picker(selection: Binding(get: { PowerMonitor.chargeAlertLevel },
                                          set: { UserDefaults.standard.set($0, forKey: "chargeAlertLevel"); state.refreshTick += 1 })) {
                    Text("Off").tag(0)
                    ForEach([80, 85, 90, 95], id: \.self) { Text("\($0)%").tag($0) }
                    Text("Fully Charged").tag(100)
                } label: {
                    RowLabel("Charge Alert", symbol: "battery.100.bolt", color: .green)
                }
                .id(state.refreshTick)
            } header: {
                Text("Battery")
            } footer: {
                footnote("A banner when the battery charges to this level, so you can unplug and save its health. Low battery and plugging in always show.")
            }
        }
        Section {
            Toggle(isOn: Binding(get: { vm.showBrightness }, set: { vm.setShowBrightness($0) })) {
                RowLabel("Monitor Brightness", symbol: "sun.max.fill", color: .blue)
            }
            if vm.showBrightness {
                LabeledContent("Monitor") {
                    Text(vm.brightness.isAvailable ? vm.brightness.displayName : "Not found")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Control") {
                    Text(vm.brightness.method == .native ? "macOS" : vm.brightness.method == .ddc ? "DDC/CI" : "None")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Shortcuts") {
                    Text("\(BrightnessHotKeys.upLabel) brighter, \(BrightnessHotKeys.downLabel) dimmer")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Display")
        } footer: {
            footnote("Dims an external monitor with macOS's own brightness control when it can, and over the cable (DDC/CI) otherwise. A sun button in the panel opens a slider; the two shortcuts suit buttons on the MX Creative Console keypad (set them in Logi Options+) and show a banner.")
        }

        Section {
            Toggle(isOn: Binding(get: { vm.showLogitech }, set: { vm.setShowLogitech($0) })) {
                RowLabel("Logitech Devices", symbol: "keyboard.fill", color: .gray)
            }
            if vm.showLogitech {
                LabeledContent("Connected") {
                    switch vm.logitech.state {
                    case .connected(let names):
                        Text(names.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    case .needsAccess:
                        Button("Allow Input Monitoring\u{2026}") {
                            NSWorkspace.shared.open(LogitechMonitor.inputMonitoringSettings)
                        }
                    case .searching, .off:
                        Text("None").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Logitech")
        } footer: {
            footnote("For devices paired over Bluetooth: the backlight level when you change it on an MX Keys keyboard, and every device's battery (low, charging, fully charged). Needs Input Monitoring to talk to them; it never reads what you type.")
        }
    }

    // MARK: - About

    @ViewBuilder
    private var about: some View {
        let updater = Updater.shared
        Section {
            LabeledContent("Version") {
                Text(Self.version).foregroundStyle(.secondary)
            }
            HStack(alignment: .center) {
                RowLabel("Software Update", symbol: "arrow.down", color: .blue)
                Spacer(minLength: 12)
                updateControl(updater)
            }
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.checksAutomatically },
                set: { updater.setChecksAutomatically($0) }))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                footnote(updateNote(updater))
                if updater.hasUpdate || updater.phase != .idle {
                    Button(updateLinkTitle(updater)) { updater.openReleasePage() }
                        .buttonStyle(.link)
                        .font(.footnote)
                }
            }
        }

        Section {
            credit("Weather", "Weather data by Open-Meteo.com and MET Norway, under CC BY 4.0.",
                   links: [("Open-Meteo", "https://open-meteo.com"), ("MET Norway", "https://api.met.no")])
            credit("Now Playing", "mediaremote-adapter by Jonas van den Berg and contributors, under the BSD 3-Clause License.",
                   links: [("Project", "https://github.com/ungive/mediaremote-adapter")],
                   license: Bundle.main.url(forResource: "mediaremote-adapter-LICENSE", withExtension: "txt"))
            credit("Lock Screen", "The lock screen layer follows SkyLightWindow by Lakr233 (MIT License).",
                   links: [("Project", "https://github.com/Lakr233/SkyLightWindow")])
        } header: {
            Text("Acknowledgements")
        }

        Section {
            // A plain row centered on its middle: LabeledContent lines the
            // button up with the title's baseline, which sat it a little high.
            HStack(alignment: .center) {
                RowLabel("Activity Report", symbol: "waveform.path.ecg", color: .red)
                Spacer(minLength: 12)
                if state.creatingReport {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Measuring\u{2026}").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Create Report\u{2026}") {
                        state.creatingReport = true
                        DiagnosticsReport.create(vm: vm) { [state] _ in state.creatingReport = false }
                    }
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            footnote("Measures Brim for five seconds, then saves a text file with what it has been doing since it started: CPU and memory, how often each part checks something, sleep and wake history, and recent events. It opens in Finder, in Library/Logs/Brim. No notification text, messages or file names, and it stays on your Mac unless you share it.")
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private func updateControl(_ updater: Updater) -> some View {
        switch updater.phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking\u{2026}").foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 110)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { updater.cancel() }
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing\u{2026}").foregroundStyle(.secondary)
            }
        default:
            if let update = updater.update {
                Button(updater.canInstall && update.dmg != nil ? "Update to \(update.version)" : "Download \(update.version)\u{2026}") {
                    updater.install()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Check for Updates") { updater.checkNow() }
            }
        }
    }

    private func updateLinkTitle(_ updater: Updater) -> String {
        guard updater.hasUpdate else { return "All Releases" }
        if case .failed = updater.phase { return "Download from GitHub" }
        return "What\u{2019}s New"
    }

    private func updateNote(_ updater: Updater) -> String {
        let checked = updater.lastChecked.map { " Checked \($0.formatted(.relative(presentation: .named)))." } ?? ""
        switch updater.phase {
        case .failed(let message):
            return message
        case .downloading, .installing:
            return "Brim opens again by itself when it\u{2019}s done. Your settings and permissions stay as they are."
        case .checking:
            return "Asking GitHub for the latest release."
        default:
            break
        }
        if let update = updater.update {
            if updater.canInstall && update.dmg != nil {
                return "Brim \(update.version) is out. Brim downloads it, makes sure it\u{2019}s signed by the same developer as this copy, swaps it in and opens again. Your settings and permissions stay."
            }
            return "Brim \(update.version) is out. This copy can\u{2019}t update itself (it was built without a signing certificate), so the button opens the download page."
        }
        if updater.phase == .upToDate {
            return "Brim \(Updater.currentVersion) is the latest version.\(checked)"
        }
        return "Brim asks GitHub for the latest release and sends nothing about you. With automatic checks on, it looks once a day.\(checked)"
    }

    /// One credit: what, who, and links (and the license file, when one ships).
    private func credit(_ title: String, _ text: String, links: [(String, String)], license: URL? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                ForEach(links.indices, id: \.self) { index in
                    if let url = URL(string: links[index].1) {
                        Link(links[index].0, destination: url).font(.caption)
                    }
                }
                if let license {
                    Button("License") { NSWorkspace.shared.open(license) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The settings window, styled like System Settings: the sidebar runs up
/// under the title bar. Brim has no Dock icon, so it activates itself to bring
/// the window to the front.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let vm: NotchViewModel
    private let state = SettingsState()

    init(vm: NotchViewModel) {
        self.vm = vm
    }

    /// Opens the window, on a given pane if there is one.
    func show(pane: SettingsPane? = nil) {
        if let pane {
            UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
        }
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(vm: vm, state: state))
            let window = NSWindow(contentViewController: controller)
            window.title = "Brim Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .hidden
            window.toolbar = NSToolbar(identifier: "BrimSettings")
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 740, height: 600))
            window.contentMinSize = NSSize(width: 720, height: 540)
            window.center()
            window.setFrameAutosaveName("BrimSettings")
            self.window = window
        }
        // The menu bar menu can change this too.
        state.launchAtLogin = SMAppService.mainApp.status == .enabled
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
