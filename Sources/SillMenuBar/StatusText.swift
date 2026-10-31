import Foundation
import SillHostCore
import StreamProtocol

/// Everything the status item, its card and its menu say, as plain values. Made by
/// `StatusText.present` from the host's snapshot, so the same words appear in the menu, the
/// tooltip, the log's "Status:" lines and the previews.
struct StatusPresentation: Equatable {
    /// A line with a symbol: the stream's source, or one device.
    struct Row: Equatable, Identifiable {
        var id: String
        var symbol: String
        var title: String
        var detail: String?
    }

    /// Something that needs the user, shown in the menu with an orange warning.
    struct Attention: Equatable, Identifiable {
        enum Action: Equatable {
            case allowScreenRecording, allowAccessibility, showRemoteAccess, showDevices
            /// Settings › General, where the macOS firewall's line has the command that unblocks Sill.
            case showGeneral
            /// "‹device› Wants to Pair": its window forward while it shows the code (`showing`), else
            /// a window opened on the Mac, asked by that device (its paired-style name).
            case pairingRequest(name: String, showing: Bool)
            case none
        }
        var title: String
        var subtitle: String
        var action: Action
        var id: String { title }
    }

    var glyph: StatusGlyph.State
    var header: String
    var subtitle: String?
    var source: Row?
    var devices: [Row]
    var attention: [Attention]
    /// Under the menu's Virtual Display item.
    var virtualDisplayNote: String
    var tooltip: String
    var accessibilityLabel: String
    /// The name devices see this Mac as, once Bonjour has registered it.
    var advertisedName: String?
    /// Under the menu's Remote Access… item: "Off", "On · Tailscale"… Nil on a host without
    /// remote access (no item then).
    var remoteAccessNote: String?
    /// Pair iPhone or iPad… can open a pairing window (the Mac has an identity).
    var canPair = false
    /// Every connected device is away from home, so the away quality is the target: the menu's
    /// Quality subtitle says so (docs/remote-bundle-plan.md §5.7).
    var away = false
}

/// Whether Sill holds its two permissions, as last read.
struct PermissionState: Equatable {
    var screenRecording: Bool
    var accessibility: Bool
}

/// The status copy. Title case in menus, sentence case in explanations, typographic quotes.
enum StatusText {
    /// How long the menu says an iPhone or iPad needs Sill updated after the home door refused one
    /// of its plain connections (docs/home-pairing-plan.md §6.4).
    static let olderDeviceShownFor: TimeInterval = 600

    /// `now`: the clock the menu's items that last a while are judged by (fixed in the previews).
    static func present(snapshot s: HostStatusSnapshot, permissions: PermissionState,
                        startupError: String?, hasCoordinator: Bool, now: Date = Date()) -> StatusPresentation {
        let (header, subtitle) = headline(s, permissions, startupError, hasCoordinator)

        var attention: [StatusPresentation.Attention] = []
        if !permissions.screenRecording {
            attention.append(.init(title: "화면 기록 허용…", subtitle: "기기에 이 Mac의 창을 표시하려면 필요합니다.",
                                   action: .allowScreenRecording))
        }
        if !permissions.accessibility {
            attention.append(.init(title: "손쉬운 사용 허용…", subtitle: "기기에서 화면은 볼 수 있지만 클릭하거나 입력할 수 없습니다.",
                                   action: .allowAccessibility))
        }
        // Kept to one line no wider than the rest of the menu: a menu item's subtitle does not wrap.
        if s.softwareEncoder, s.hardwareEncoderStuck {
            attention.append(.init(title: "하드웨어 인코더 응답 없음",
                                   subtitle: "소프트웨어 인코더로 최대 60 fps까지 전송합니다. Mac을 재시동하면 해결됩니다.",
                                   action: .none))
        } else if s.softwareEncoder {
            attention.append(.init(title: "하드웨어 인코더 사용 중",
                                   subtitle: "인코더를 사용할 수 있을 때까지 소프트웨어 인코더로 최대 60 fps까지 전송합니다.",
                                   action: .none))
        }
        let remotePortTaken = remotePortInUse(s.remote)
        if let port = remotePortTaken {
            attention.append(.init(title: "원격 접근을 시작할 수 없음", subtitle: "다른 앱이 포트 \(port)를 사용 중입니다.",
                                   action: .showRemoteAccess))
        }
        // Pairing at home (docs/home-pairing-plan.md §6.4).
        let request = pairingRequest(s.remote, now: now)
        if let request { attention.append(request) }
        if let at = s.remote?.olderDeviceAt, now.timeIntervalSince(at) < olderDeviceShownFor {
            attention.append(.init(title: "iPhone 또는 iPad의 Sill 업데이트 필요", subtitle: "이전 버전의 Sill에서 연결을 시도했습니다.",
                                   action: .none))
        }
        let homeDoorClosed = homeDoorUnavailable(s.remote)
        if homeDoorClosed {
            attention.append(.init(title: "기기를 연결할 수 없음", subtitle: "Sill이 키체인의 키를 사용할 수 없습니다.",
                                   action: .showDevices))
        }
        // The macOS firewall blocks Sill (FirewallRule): its line and command are in Settings › General.
        // Not beside the keychain's: with no home door there is nothing for the firewall to block.
        let firewallBlocks = !homeDoorClosed ? s.firewall.flatMap(FirewallRule.Copy.menuSubtitle) : nil
        if let firewallBlocks {
            attention.append(.init(title: "기기를 연결할 수 없음", subtitle: firewallBlocks, action: .showGeneral))
        }

        // The attention glyph means "Sill needs you". The test pattern needs no permission. A device
        // waiting to pair, a closed home door and a firewall that blocks Sill need the user too; an
        // older device is only news.
        let glyph: StatusGlyph.State
        if startupError != nil || isFailed(s.network) || remotePortTaken != nil || request != nil || homeDoorClosed
            || firewallBlocks != nil
            || (!s.synthetic && !(permissions.screenRecording && permissions.accessibility)) {
            glyph = .attention
        } else if s.stream != nil {
            glyph = .streaming
        } else if !s.devices.isEmpty {
            glyph = .connected
        } else {
            glyph = .idle
        }

        var name: String?
        if case .advertising(let n) = s.network { name = n }

        return StatusPresentation(glyph: glyph, header: header, subtitle: subtitle,
                                  source: sourceRow(s), devices: s.devices.map(deviceRow), attention: attention,
                                  virtualDisplayNote: virtualDisplayNote(s),
                                  tooltip: "Sill — \(header)", accessibilityLabel: "Sill, \(header)",
                                  advertisedName: name, remoteAccessNote: remoteAccessNote(s.remote),
                                  canPair: s.remote.map { $0.identityProblem == nil } ?? false, away: s.away)
    }

    /// "iPad Wants to Pair", for 5 minutes after a device's ask (the host ends it sooner: when the
    /// window showing its code closes, and when that device pairs): "A code is showing." while that
    /// window is up, "Click to show a code." when the ask limits kept one from opening, the unlock
    /// line when this Mac was locked. Sentences with a full stop, as every attention subtitle is.
    /// Never for an ask from this Mac itself (the host sets none).
    private static func pairingRequest(_ r: RemoteStatus?, now: Date) -> StatusPresentation.Attention? {
        guard let request = r?.pairingRequest, now.timeIntervalSince(request.at) < RemoteStatus.PairingRequest.shownFor else { return nil }
        let short = shortName(request.name)
        let subtitle: String
        switch request.reason {
        case "showing": subtitle = "페어링 코드가 표시되어 있습니다."
        case "locked": subtitle = "이 Mac의 잠금을 해제한 뒤 \(short)에서 이 Mac을 다시 선택하세요."
        default: subtitle = "클릭하면 페어링 코드가 표시됩니다."
        }
        return .init(title: "\(short)의 페어링 요청", subtitle: subtitle,
                     action: .pairingRequest(name: request.name, showing: request.reason == "showing"))
    }

    /// The home door has no listener: the identity (its key, the trust list) could not be used.
    private static func homeDoorUnavailable(_ r: RemoteStatus?) -> Bool {
        if case .unavailable? = r?.homeDoor { return true }
        return false
    }

    /// The remote door's port while Remote Access is on and another app holds that port.
    private static func remotePortInUse(_ r: RemoteStatus?) -> Int? {
        guard let r, r.remoteAccess, r.identityProblem == nil, case .portInUse(let port) = r.listener else { return nil }
        return port
    }

    /// The Remote Access… item's subtitle: "Off", "On · Tailscale", "On · Tailscale and the
    /// internet", "On · no VPN on this Mac", "Port 7455 is in use" or "Unavailable: the keychain
    /// couldn’t be used".
    static func remoteAccessNote(_ r: RemoteStatus?) -> String? {
        guard let r else { return nil }
        if r.identityProblem != nil { return "사용 불가: 키체인을 사용할 수 없음" }
        guard r.remoteAccess else { return "꺼짐" }
        switch r.listener {
        case .portInUse(let port): return "포트 \(port) 사용 중"
        case .failed: return "시작하지 못해 다시 시도 중"
        case .off, .listening: break
        }
        var ways: [String] = []
        for a in r.addresses where a.kind == MacAddress.vpn && !ways.contains(a.via) { ways.append(a.via) }
        if r.internetAccess { ways.append("인터넷") }
        guard let last = ways.last else { return "켜짐 · 이 Mac에 VPN이 없음" }
        return "켜짐 · " + (ways.count == 1 ? last : ways.dropLast().joined(separator: ", ") + " 및 " + last)
    }

    /// The header and its explanation; the first match wins.
    private static func headline(_ s: HostStatusSnapshot, _ permissions: PermissionState, _ startupError: String?,
                                 _ hasCoordinator: Bool) -> (String, String?) {
        if let startupError { return ("Sill을 시작할 수 없음", startupError) }
        if !hasCoordinator { return ("시작 중…", nil) }
        // No listener at all (fail closed): no device can find or reach this Mac.
        if homeDoorUnavailable(s.remote) {
            return ("네트워크에 표시되지 않음",
                    "Sill이 키체인의 키를 사용할 수 없습니다. Sill을 종료한 뒤 다시 열고, 키체인에서 묻는 경우 ‘항상 허용’을 선택하세요.")
        }
        switch s.network {
        case .starting:
            return ("시작 중…", nil)
        case .failed(let error):
            return ("네트워크에 표시되지 않음", "\(error). Sill을 종료한 뒤 다시 열어 보세요.")
        case .waiting:
            return ("네트워크 연결 대기 중",
                    "이 Mac을 Wi‑Fi 또는 이더넷에 연결하고 로컬 네트워크 접근을 허용하면 iPhone과 iPad에 Sill이 표시됩니다.")
        case .notAdvertised(let port):
            return ("테스트 패턴 모드", "네트워크에 표시하지 않습니다. 테스트 클라이언트는 포트 \(port)에 연결합니다.")
        case .registering, .advertising:
            break
        }
        if !permissions.screenRecording {
            return ("화면 기록 권한 없음", "기기를 연결할 수 있지만 창은 볼 수 없습니다.")
        }
        let count = s.devices.count
        if count > 0 {
            let who = count == 1 ? (s.devices[0].name.map(shortName) ?? "기기") : "기기 \(count)대"
            if s.stream != nil { return ("\(who)에 영상 전송 중", nil) }
            let connected = count == 1 ? (s.devices[0].name.map(shortName) ?? "기기") : "기기 \(count)대"
            return ("\(connected) 연결됨", "기기에서 창을 선택하면 영상 전송을 시작합니다.")
        }
        if case .advertising(let name) = s.network {
            return ("기기 연결 대기 중", "iPhone 또는 iPad에서 Sill을 여세요. 이 Mac은 “\(name)” 이름으로 표시됩니다.")
        }
        return ("기기 연결 대기 중", "로컬 네트워크에 등록 중…")
    }

    private static func isFailed(_ n: HostStatusSnapshot.Network) -> Bool {
        if case .failed = n { return true }
        return false
    }

    /// "iPad" from "iPad (iPad14,1)".
    static func shortName(_ device: String) -> String {
        let name = device.components(separatedBy: " (").first ?? device
        return name.isEmpty ? device : name
    }

    /// What streams: "Safari — Apple Developer" over "3024×1898 · 118 of 120 fps · 30 Mbps" (a still
    /// picture: "120 fps, still"), and with one device, how it is connected: "… · 30 Mbps · Wi-Fi".
    /// With two or more, each device's own row says it. "· sound" ends it while a device gets the
    /// Mac's sound.
    private static func sourceRow(_ s: HostStatusSnapshot) -> StatusPresentation.Row? {
        guard let stream = s.stream else { return nil }
        let title: String, symbol: String
        switch stream.kind {
        case .window: title = middleTruncated(stream.title, to: 44); symbol = "macwindow"
        case .desktop: title = "전체 데스크탑"; symbol = "menubar.dock.rectangle"
        case .testPattern: title = "테스트 패턴"; symbol = "checkerboard.rectangle"
        }
        // The encoder only produces a frame when the picture changed (ScreenCaptureKit delivers
        // frames on repaint), so 0 means a still window, not a stalled stream. "120 fps, still" is
        // about as wide as a one-digit count ("5 of 120 fps"), so a row wraps the same still as
        // changing, unless the count's own digits tip it: the open menu resizes the card on every
        // change, and "nothing changing" with the route word made it jump a line each time a
        // window stopped or started changing.
        let rate = s.encodedFPS > 0 ? "\(min(s.encodedFPS, stream.fps))/\(stream.fps) fps" : "\(stream.fps) fps, 정지 화면"
        var detail = "\(stream.width)×\(stream.height) · \(rate) · \(stream.mbps) Mbps"
        if s.devices.count == 1, let route = routeWord(s.devices[0]) { detail += " · \(route)" }
        if stream.onVirtualDisplay {
            detail += " · 가상 디스플레이"
        } else if s.virtualDisplayOn, stream.kind == .window {
            detail += " · 원래 창 (가상 디스플레이: \(s.lastStageFailure ?? s.virtualDisplayProblem ?? "사용 불가"))"
        }
        if stream.softwareEncoder { detail += " · 소프트웨어 인코더" }
        // The Mac's sound goes out too, while a device gets it (docs/audio-plan.md, Q9).
        if s.audio?.devices ?? 0 > 0 { detail += " · 오디오" }
        return StatusPresentation.Row(id: "source", symbol: symbol, title: title, detail: detail)
    }

    /// "iPad (iPad14,1)" over "118 fps · frame age 9 ms · RTT 7 ms · Wi-Fi" (from away: "… · through
    /// Tailscale"); the address until the device's first report (within a second; a remote device
    /// shows its paired name), and until then the route alone. A second without a sample reads
    /// "–", as in the host's log line and the device's HUD: a still window sends no frames
    /// (ScreenCaptureKit delivers only repaints), and a second can pass without a pong. While its
    /// link does not keep up (docs/remote-bundle-plan.md §6.6) the numbers give way to it, the frame
    /// age dropping out to keep the row short: "3 fps, the link can’t carry Pro · RTT 531 ms ·
    /// through Tailscale", or "Nothing is getting through · through Tailscale".
    private static func deviceRow(_ d: HostStatusSnapshot.Device) -> StatusPresentation.Row {
        let name = d.name ?? d.endpoint
        let symbol = name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "ipad"
        var parts: [String] = []
        if let link = d.link {
            parts.append(linkWords(link, fps: d.fps, rttMs: d.rttMs))
        } else if let fps = d.fps, let age = d.frameAgeMs, let rtt = d.rttMs {
            parts.append("\(fps) fps · 프레임 지연 \(ms(age)) · RTT \(ms(rtt))")
        }
        if let route = routeWord(d) { parts.append(route) }
        return StatusPresentation.Row(id: String(describing: d.id), symbol: symbol, title: name,
                                      detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    /// A device's link that does not keep up, as its row says it: behind, "3 fps, the link can’t carry
    /// Pro · RTT 531 ms" (the fps and the round trip when its stats have come); stalled, "Nothing is
    /// getting through".
    static func linkWords(_ link: HostStatusSnapshot.LinkStatus, fps: Int?, rttMs: Int?) -> String {
        switch link.state {
        case .stalled:
            return "영상이 수신되지 않음"
        case .behind:
            let quality = QualityPreset.koreanName(forBitrate: link.bitrate).replacingOccurrences(of: " ", with: "\u{00A0}")
            var words = (fps.map { "\($0) fps, " } ?? "") + "연결 속도가 \(quality) 전송에 부족함"
            if let rtt = rttMs { words += " · RTT \(ms(rtt))" }
            return fps == nil ? words.prefix(1).uppercased() + words.dropFirst() : words
        }
    }

    /// How a device reaches this Mac, the one place the card decides it (the device's row, and the
    /// source row while it is the only device). A remote session says how it came ("through
    /// Tailscale", "over the internet"; RemoteServer's label), which always wins: its link from
    /// this Mac's side would read "Wi-Fi" for a session over the internet. A home device gets its
    /// link from this Mac's side of its connection (ClientLink.route), in the words the device's
    /// connect screen and Settings panel use; nil when neither says (loopback, an interface of no
    /// known kind). Either is kept whole when a detail wraps: a remote label's spaces are no-break
    /// ones (the source row wrapped "through" and "Tailscale" onto two lines), as Wi-Fi's hyphen is.
    private static func routeWord(_ d: HostStatusSnapshot.Device) -> String? {
        if let remote = d.remoteRoute { return koreanRoute(remote).replacingOccurrences(of: " ", with: "\u{00A0}") }
        return d.route.map(word)
    }

    static func koreanRoute(_ text: String) -> String {
        switch text {
        case "through your VPN": return "VPN 경유"
        case "over the internet": return "인터넷"
        case "by address": return "주소로 연결"
        case "on this Mac": return "이 Mac"
        case "on this network": return "현재 네트워크"
        case "nearby": return "근처"
        case "over the USB cable": return "USB 케이블"
        case "over Wi\u{2011}Fi", "over Wi-Fi": return "Wi‑Fi"
        case "over Ethernet": return "이더넷"
        case "directly": return "직접 연결"
        case "at home": return "내부 네트워크"
        default:
            return text.hasPrefix("through ") ? String(text.dropFirst("through ".count)) + " 경유" : text
        }
    }

    /// A home device's link as the card words it. "Wi-Fi" has a non-breaking hyphen, so a wrapped
    /// detail never splits it.
    private static func word(_ route: ClientLink.Route) -> String {
        switch route {
        case .wired: return "유선"
        case .wifi: return "Wi\u{2011}Fi"
        case .direct: return "직접 연결"
        }
    }

    /// One of a device's reported times. Negative is the client's "no sample this second" (-1),
    /// never a time.
    private static func ms(_ v: Int) -> String { v < 0 ? "–" : "\(v) ms" }

    private static func virtualDisplayNote(_ s: HostStatusSnapshot) -> String {
        if let problem = s.virtualDisplayProblem { return "사용 불가: \(problem)" }
        if s.virtualDisplayOn, s.stream?.onVirtualDisplay == true { return "전송 중인 창이 가상 디스플레이에 있습니다" }
        return "선택한 창은 전송하는 동안 이 화면에서 이동합니다"
    }

    /// "Safari — A very long window title that goes on" → "Safari — A very long…that goes on".
    static func middleTruncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let keep = limit - 1
        return String(text.prefix((keep + 1) / 2)) + "…" + String(text.suffix(keep / 2))
    }
}
