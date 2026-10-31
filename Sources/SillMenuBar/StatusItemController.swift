import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// One line of the status menu, as data. `MenuBuilder` makes the list, the status item turns it
/// into NSMenuItems, and the previews hook prints it to menu.txt, so the three cannot disagree.
struct MenuEntry: Equatable {
    enum Kind: Equatable { case card, item, separator }
    enum Action: Equatable {
        case none
        case allowScreenRecording, allowAccessibility, openPrivacy
        /// These two are absolute, like the radio items: each sets what the item offered when the
        /// menu was built (on when it showed unchecked). A device can change the setting while the
        /// menu is open, which does not rebuild it, and a toggle would then do the opposite of what
        /// the item shows.
        case setVirtualDisplay(Bool)
        case setDirectWireless(Bool)
        case setSendAudio(Bool)
        case setMaxFPS(Int), setBitrate(Int), setCaptureScale(CGFloat)
        case toggleLaunchAtLogin
        case showLog, showSettings, quit
        /// Settings on one tab (Remote Access…); the plain `showSettings` stays for ⌘,. (Swift
        /// allows no second case named `showSettings`.)
        case showSettingsTab(SettingsTab)
        /// Pair iPhone or iPad…: a pairing window, or the open one brought forward.
        case showPairing
        /// "‹device› Wants to Pair": the window that shows its code brought forward, else one
        /// opened on the Mac, asked by that device.
        case showPairingRequest(name: String, showing: Bool)
        /// Sill 0.4 Is Available…: the release's page on GitHub, in the browser (UpdateChecker).
        case openUpdate(URL)
    }

    var kind: Kind
    var title = ""
    var subtitle: String?
    var checked = false
    var enabled = true
    /// An orange warning in front: something needs the user.
    var attention = false
    /// ⌘ plus this key.
    var key = ""
    var action: Action = .none
    var children: [MenuEntry] = []

    static let separator = MenuEntry(kind: .separator)
}

/// Launch at login as the menu shows it.
struct LoginState: Equatable {
    var available: Bool
    var on: Bool
    var needsApproval: Bool
    var error: String?
}

/// The status menu, top to bottom. Titles are title case, subtitles sentence case. The controls
/// mirror the Settings window and only ever set the app's settings.
enum MenuBuilder {
    /// `update`: a newer release the update check found, and this Sill's version: one item right
    /// after the card and anything needing attention. The glyph never changes for it: the attention
    /// glyph means Sill needs the person before it can work, and an update needs nothing.
    static func entries(presentation p: StatusPresentation, config: HostConfig, login: LoginState,
                        permissions: PermissionState,
                        update: (offer: UpdatePolicy.Offer, running: SillVersion)? = nil) -> [MenuEntry] {
        var menu: [MenuEntry] = [MenuEntry(kind: .card, title: p.header)]
        for a in p.attention {
            let action: MenuEntry.Action = switch a.action {
            case .allowScreenRecording: .allowScreenRecording
            case .allowAccessibility: .allowAccessibility
            case .showRemoteAccess: .showSettingsTab(.remoteAccess)
            case .showDevices: .showSettingsTab(.devices)
            case .showGeneral: .showSettingsTab(.general)
            case .pairingRequest(let name, let showing): .showPairingRequest(name: name, showing: showing)
            case .none: .none
            }
            menu.append(MenuEntry(kind: .item, title: a.title, subtitle: a.subtitle, enabled: action != .none,
                                  attention: true, action: action))
        }
        if let update {
            menu.append(MenuEntry(kind: .item, title: UpdatePolicy.menuTitle(update.offer),
                                  subtitle: UpdatePolicy.menuSubtitle(running: update.running), action: .openUpdate(update.offer.url)))
        }
        menu.append(.separator)

        menu.append(MenuEntry(kind: .item, title: "가상 디스플레이", subtitle: p.virtualDisplayNote,
                              checked: config.virtualDisplay, action: .setVirtualDisplay(!config.virtualDisplay)))
        menu.append(MenuEntry(kind: .item, title: "프레임률", children: [60, 120].map { fps in
            MenuEntry(kind: .item, title: "최대 \(fps) fps", checked: config.maxFPS == fps, action: .setMaxFPS(fps))
        }))
        var quality = QualityPreset.allCases.map { preset in
            MenuEntry(kind: .item, title: preset.koreanTitle, checked: config.bitrate == preset.rawValue, action: .setBitrate(preset.rawValue))
        }
        if QualityPreset(rawValue: config.bitrate) == nil {
            quality.append(MenuEntry(kind: .item, title: QualityPreset.koreanTitle(forBitrate: config.bitrate), checked: true, enabled: false))
        }
        // The home quality, as ever; while every connected device is away, the subtitle says which
        // quality runs instead (the away one is set in Settings › Streaming, never here).
        let qualityNote = p.away
            ? "외부 네트워크 품질 적용 중: \(QualityPreset.koreanShortTitle(bitrate: config.awayBitrate, captureScale: Double(config.awayCaptureScale)))"
            : "60 fps 기준이며, 120 fps 영상은 두 배를 사용합니다"
        menu.append(MenuEntry(kind: .item, title: "영상 품질", subtitle: qualityNote, children: quality))
        // Standard is one pixel a point: a quarter of a Retina display's pixels, and on a 1x display
        // the same capture as Retina (CaptureScale holds the knob to the display's own scale).
        menu.append(MenuEntry(kind: .item, title: "해상도", children: [
            MenuEntry(kind: .item, title: "레티나", checked: config.captureScale >= 1.5, action: .setCaptureScale(2)),
            MenuEntry(kind: .item, title: "표준", subtitle: "레티나 디스플레이에서 인코딩 픽셀 수가 1/4로 줄어듭니다",
                      checked: config.captureScale < 1.5, action: .setCaptureScale(1)),
        ]))
        // The last of what streams: the sound of it (docs/audio-plan.md §6), a beta, which its title
        // says (in the title, so menu.txt and VoiceOver have it too). Absolute, like Virtual Display:
        // it sets the value it showed.
        menu.append(MenuEntry(kind: .item, title: "오디오 전송 (베타)", subtitle: "Mac에서도 오디오가 계속 재생됩니다",
                              checked: config.sendAudio, action: .setSendAudio(!config.sendAudio)))
        menu.append(.separator)

        // How Sill runs on this Mac, not the picture: devices reach it over peer-to-peer Wi-Fi too.
        // Here as well as in Settings because it is situational (on in a café, off at home).
        menu.append(MenuEntry(kind: .item, title: "직접 무선 연결",
                              subtitle: "같은 네트워크 없이 연결합니다. Wi‑Fi 영상이 끊길 수 있습니다",
                              checked: config.directWireless, action: .setDirectWireless(!config.directWireless)))
        // Opens the pane rather than toggling: turning it on is worth reading what it does, and the
        // internet switch stays one deliberate step deeper, never in the menu.
        if let note = p.remoteAccessNote {
            menu.append(MenuEntry(kind: .item, title: "원격 접근…", subtitle: note, action: .showSettingsTab(.remoteAccess)))
        }
        var loginNote: String?
        if !login.available { loginNote = "Sill 앱으로 실행할 때 사용할 수 있습니다" }
        else if let error = login.error { loginNote = error }
        else if login.needsApproval { loginNote = "시스템 설정 › 로그인 항목에서 Sill을 허용하세요" }
        menu.append(MenuEntry(kind: .item, title: "로그인 시 실행", subtitle: loginNote, checked: login.on,
                              enabled: login.available, action: .toggleLaunchAtLogin))
        menu.append(MenuEntry(kind: .item, title: "권한", children: [
            permissions.screenRecording
                ? MenuEntry(kind: .item, title: "화면 기록: 허용됨", enabled: false)
                : MenuEntry(kind: .item, title: "화면 기록: 허용되지 않음…", action: .allowScreenRecording),
            permissions.accessibility
                ? MenuEntry(kind: .item, title: "손쉬운 사용: 허용됨", enabled: false)
                : MenuEntry(kind: .item, title: "손쉬운 사용: 허용되지 않음…", action: .allowAccessibility),
            .separator,
            MenuEntry(kind: .item, title: "개인정보 보호 및 보안 열기…", action: .openPrivacy),
        ]))
        menu.append(.separator)

        if p.remoteAccessNote != nil {
            menu.append(MenuEntry(kind: .item, title: "iPhone 또는 iPad 페어링…", enabled: p.canPair, action: .showPairing))
        }
        menu.append(MenuEntry(kind: .item, title: "로그 보기…", action: .showLog))
        menu.append(MenuEntry(kind: .item, title: "설정…", key: ",", action: .showSettings))
        menu.append(.separator)
        menu.append(MenuEntry(kind: .item, title: "Sill 종료", key: "q", action: .quit))
        return menu
    }

    /// The live menu for `model` as it would open now (the status item's rebuild, and
    /// -SillPrintMenuAfter): its presentation, settings, login item, permissions and any update the
    /// check found.
    @MainActor
    static func entries(for model: AppModel) -> [MenuEntry] {
        let login = LoginState(available: model.loginItem.available, on: model.loginItem.isOn,
                               needsApproval: model.loginItem.needsApproval, error: model.loginItem.error)
        let permissions = PermissionState(screenRecording: model.permissions.screenRecording,
                                          accessibility: model.permissions.accessibility)
        let update = model.updates.offer.flatMap { offer in model.updates.runningVersion.map { (offer: offer, running: $0) } }
        return entries(presentation: model.presentation, config: model.settings.config, login: login, permissions: permissions,
                       update: update)
    }

    /// The menu as text, for the previews: "✓" checked, "⚠" attention, "(off)" disabled.
    static func dump(_ entries: [MenuEntry], card: StatusPresentation? = nil, indent: String = "") -> String {
        var out = ""
        for e in entries {
            switch e.kind {
            case .separator:
                out += indent + "────────\n"
            case .card:
                guard let p = card else { out += indent + "[card]\n"; continue }
                out += indent + "[card] \(p.header)\n"
                if let s = p.subtitle { out += indent + "       \(s)\n" }
                for row in [p.source].compactMap({ $0 }) + p.devices {
                    out += indent + "       · \(row.title)\(row.detail.map { " — \($0)" } ?? "")\n"
                }
            case .item:
                let mark = e.attention ? "⚠ " : (e.checked ? "✓ " : "  ")
                var line = indent + mark + e.title
                if !e.key.isEmpty { line += "  ⌘" + e.key.uppercased() }
                if !e.enabled { line += "  (off)" }
                if let s = e.subtitle { line += "  — \(s)" }
                out += line + (e.children.isEmpty ? "\n" : " ▸\n")
                if !e.children.isEmpty { out += dump(e.children, indent: indent + "    ") }
            }
        }
        return out
    }
}

/// The menu bar item and its menu. The menu is rebuilt each time it opens (permissions and the
/// login item re-read first), and the status card inside it follows the host live while it is
/// open. Every control only sets `model.settings.config`, the one path to the coordinator.
///
/// Its actions are AppKit target/action, the one safe place to start what may run a modal loop
/// (NSApp.terminate): see AppDelegate.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let model: AppModel
    private let card: NSHostingView<LiveStatusCard>
    private var glyph: StatusGlyph.State?
    private var menuOpen = false

    private static let attentionImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "확인 필요")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }()

    init(model: AppModel) {
        self.model = model
        card = NSHostingView(rootView: LiveStatusCard(model: model))
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "SillStatusItem"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        show(model.presentation)
    }

    /// The glyph, tooltip and accessibility label for a new presentation.
    func show(_ p: StatusPresentation) {
        guard let button = item.button else { return }
        if glyph != p.glyph {
            glyph = p.glyph
            button.image = StatusGlyph.image(p.glyph)
        }
        button.toolTip = p.tooltip
        button.setAccessibilityLabel(p.accessibilityLabel)
        // A device joining while the menu is open makes the card taller.
        if menuOpen { card.frame.size = card.fittingSize }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.permissions.refresh()
        model.loginItem.refresh()
        // The macOS firewall asked again (FirewallCheck: read-only, a few ms, off the main thread), so
        // a block that came after launch (a Deny in the firewall's own prompt, Block all incoming
        // connections turned on) is told where the user looks when devices can't connect: the glyph at
        // once, Devices Can’t Connect from the menu's next opening (it is built before the answer).
        model.coordinator?.checkFirewall()
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func rebuild() {
        menu.removeAllItems()
        for entry in MenuBuilder.entries(for: model) {
            menu.addItem(makeItem(entry))
        }
    }

    private func makeItem(_ e: MenuEntry) -> NSMenuItem {
        switch e.kind {
        case .separator:
            return .separator()
        case .card:
            let cardItem = NSMenuItem()
            card.frame = NSRect(origin: .zero, size: card.fittingSize)
            cardItem.view = card
            return cardItem
        case .item:
            let menuItem = NSMenuItem(title: e.title, action: e.action == .none ? nil : #selector(menuAction(_:)), keyEquivalent: e.key)
            menuItem.target = self
            menuItem.representedObject = e.action
            menuItem.state = e.checked ? NSControl.StateValue.on : .off
            menuItem.isEnabled = e.enabled
            if let subtitle = e.subtitle {
                if #available(macOS 14.4, *) { menuItem.subtitle = subtitle } else { menuItem.toolTip = subtitle }
            }
            if e.attention { menuItem.image = Self.attentionImage }
            if !e.children.isEmpty {
                let submenu = NSMenu(title: e.title)
                submenu.autoenablesItems = false
                for child in e.children { submenu.addItem(makeItem(child)) }
                menuItem.submenu = submenu
            }
            return menuItem
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuEntry.Action else { return }
        switch action {
        case .none: break
        case .allowScreenRecording: model.permissions.requestScreenRecording()
        case .allowAccessibility: model.permissions.requestAccessibility()
        case .openPrivacy: model.permissions.openPrivacyPane()
        case .setVirtualDisplay(let on): model.settings.config.virtualDisplay = on
        case .setDirectWireless(let on): model.settings.config.directWireless = on
        case .setSendAudio(let on): model.settings.config.sendAudio = on
        case .setMaxFPS(let fps): model.settings.config.maxFPS = fps
        case .setBitrate(let bitrate): model.settings.config.bitrate = bitrate
        case .setCaptureScale(let scale): model.settings.config.captureScale = scale
        case .toggleLaunchAtLogin: model.loginItem.set(!model.loginItem.isOn)
        case .showLog: model.showLog?()
        case .showSettings: model.showSettings?(nil)
        case .showSettingsTab(let tab): model.showSettings?(tab)
        case .showPairing: model.pairDevice()
        case .showPairingRequest(let name, let showing): model.showPairingRequest(name: name, showing: showing)
        case .openUpdate(let url): NSWorkspace.shared.open(url)   // the browser; no modal loop
        case .quit: NSApp.terminate(nil)
        }
    }
}
