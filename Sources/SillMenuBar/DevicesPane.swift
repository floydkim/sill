import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// Settings › Devices, live: Require pairing, which the model keeps in the identity store beside
/// the trust list (never in UserDefaults), the pairing window's switch for screen sharing (in
/// UserDefaults, HostSettings), and the paired devices from the host's status (pushed, so nothing
/// polls), with the model's actions.
struct LiveDevicesPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        DevicesPane(status: model.coordinator?.status.snapshot.remote ?? RemoteStatus(),
                    requirePairing: Binding(get: { settings.config.requirePairing }, set: { model.setRequirePairing($0) }),
                    showPairingWindowToScreenSharing: $settings.showPairingWindowToScreenSharing,
                    requirePairingProblem: model.requirePairingProblem,
                    actions: DevicesPane.Actions(pair: { model.pairDevice() },
                                                 remove: { model.removeDevice($0) },
                                                 rename: { model.renameDevice($0, to: $1) }))
    }
}

/// The Devices pane (docs/home-pairing-plan.md §6.1): Require pairing; Show the pairing window to
/// screen sharing (issue #108, PairingWindowSharing); and the devices paired with this Mac at home
/// and from afar (one trust list), each with how it paired and how it last connected, Remove, rename
/// and Pair iPhone or iPad…. Values in, actions out, so the previews can draw every state. Errors
/// show inline, never in alerts.
struct DevicesPane: View {
    struct Actions {
        var pair: () -> Void = {}
        /// Nil when the device was removed; otherwise why it is still paired.
        var remove: (String) -> String? = { _ in nil }
        var rename: (String, String) -> Void = { _, _ in }
    }

    let status: RemoteStatus
    @Binding var requirePairing: Bool
    /// Screen Sharing and other remote desktop apps show the pairing window (off by default).
    @Binding var showPairingWindowToScreenSharing: Bool
    /// The last Require pairing change the identity store did not keep.
    var requirePairingProblem: AppModel.RequirePairingProblem?
    let actions: Actions
    /// "Last connected 2 minutes ago" counts from here (fixed in the previews).
    var now: Date?

    @State private var removedName: String?
    /// A Remove the keychain did not keep: the device's name and why.
    @State private var removeProblem: (name: String, reason: String)?

    /// Why devices can't connect at all: the identity (the key, the trust list) could not be used,
    /// so the home door has no listener. Nil when it works.
    private var unavailable: String? {
        if let problem = status.identityProblem { return problem }
        if case .unavailable(let why) = status.homeDoor { return why }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("페어링 필수", isOn: $requirePairing)
                    .disabled(unavailable != nil)
                if let problem = unavailable {
                    Warning("기기를 연결할 수 없습니다. Sill이 키체인의 키를 사용할 수 없습니다(\(withoutFullStop(problem))). Sill을 종료한 뒤 다시 열고, 키체인에서 묻는다면 ‘항상 허용’을 선택하세요.")
                } else if let p = requirePairingProblem {
                    let reason = withoutFullStop(p.reason)
                    Warning(p.wanted
                            ? "Sill을 종료할 때까지 페어링이 필수입니다. 키체인을 갱신할 수 없습니다(\(reason)). 다시 시도하세요."
                            : "페어링이 계속 필수입니다. 키체인을 갱신할 수 없습니다(\(reason)). 다시 시도하세요.")
                }
            } footer: {
                if requirePairing {
                    Footnote("각 iPhone이나 iPad는 한 번만 페어링하면 됩니다. USB 케이블로 자동 페어링하거나, Wi‑Fi에서 기기의 요청에 따라 이 Mac에 표시되는 코드를 사용합니다. 기기가 주고받는 모든 데이터는 암호화됩니다.")
                } else {
                    Label("네트워크의 모든 기기와 이 Mac의 모든 앱이 페어링 없이 화면을 보고 조작할 수 있습니다. 직접 무선 연결을 켰다면 근처 기기도 가능합니다. 연결은 계속 암호화됩니다.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Toggle("화면 공유에 페어링 창 표시", isOn: $showPairingWindowToScreenSharing)
            } footer: {
                Footnote("화면 공유나 다른 원격 데스크탑 앱으로 이 Mac을 사용하는 동안 페어링하려면 켜세요. 켜 두면 이 Mac의 화면을 원격으로 볼 수 있는 사람은 코드를 읽을 수 있습니다. Sill로 이 Mac의 영상을 보는 기기에는 페어링 창이 표시되지 않습니다.")
            }
            pairedDevices
        }
    }

    private var pairedDevices: some View {
        Section {
            if let removedName {
                Text("\(removedName) 기기의 연결 권한을 해제했습니다. 다시 사용하려면 페어링해야 합니다.")
            }
            if let removeProblem {
                Warning("\(removeProblem.name) 기기가 아직 페어링되어 있습니다. 키체인을 갱신할 수 없습니다(\(withoutFullStop(removeProblem.reason))). 다시 시도하세요.")
            }
            if unavailable != nil {
                // The trust list lives with the key: unread, not empty.
                Text("Sill이 키를 다시 사용할 수 있게 되면 페어링한 기기가 여기에 표시됩니다.").foregroundStyle(.secondary)
            } else if status.paired.isEmpty {
                Text("아직 페어링한 기기가 없습니다.").foregroundStyle(.secondary)
            }
            ForEach(status.paired) { device in
                PairedDeviceRow(device: device, now: now,
                                remove: {
                                    // Said only once the keychain kept it: otherwise the device
                                    // would be trusted again at the next launch.
                                    if let reason = actions.remove(device.id) {
                                        removedName = nil
                                        removeProblem = (device.name, reason)
                                    } else {
                                        removedName = device.name
                                        removeProblem = nil
                                    }
                                },
                                rename: { actions.rename(device.id, $0) })
            }
            Button("iPhone 또는 iPad 페어링…") { actions.pair() }
                .disabled(unavailable != nil)
        } header: {
            Text("페어링한 기기")
        } footer: {
            Footnote("페어링한 기기는 같은 네트워크나 근처에서 이 Mac을 보고 조작할 수 있으며, 원격 접속을 켜면 외부에서도 가능합니다. 기기를 분실했다면 여기서 제거하세요.")
        }
    }
}

/// One paired device: its name (double-click to rename: Return saves, Esc cancels), how it paired,
/// when and how it last connected (at home or from away), and Remove, with no confirmation since
/// it only takes access away.
struct PairedDeviceRow: View {
    let device: PairedDeviceSummary
    let now: Date?
    let remove: () -> Void
    let rename: (String) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            Button("제거", action: remove)
        } label: {
            if editing {
                TextField("이름", text: $text)
                    .focused($focused)
                    .onSubmit {
                        rename(text)
                        editing = false
                    }
                    .onExitCommand { editing = false }
            } else {
                Text(device.name)
                    .onTapGesture(count: 2) { startEditing() }
                    .accessibilityAction(named: "이름 변경") { startEditing() }
            }
            Text(Self.detail(device, now: now ?? Date()))
        }
    }

    private func startEditing() {
        text = device.name
        editing = true
        focused = true
    }

    /// "Paired Sep 25 over the USB cable · last connected 2 minutes ago over Wi‑Fi", "Paired Sep 24
    /// with the QR code · last connected yesterday through Tailscale".
    static func detail(_ device: PairedDeviceSummary, now: Date) -> String {
        var out = "페어링: \(day(device.pairedAt, now: now))"
        switch device.method {
        case PairRequest.qr: out += " · QR 코드"
        case PairRequest.code: out += " · 코드 입력"
        case PairResult.cable: out += " · USB 케이블"
        default: break
        }
        if let seen = device.lastSeen {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .named
            let when = now.timeIntervalSince(seen) < 60 ? "방금" : formatter.localizedString(for: seen, relativeTo: now)
            out += " · 마지막 연결: \(when)"
            if let route = device.lastRoute { out += " · \(StatusText.koreanRoute(route))" }
        }
        return out
    }

    static func day(_ date: Date, now: Date) -> String {
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "ko_KR"))) : date.formatted(.dateTime.month(.abbreviated).day().year().locale(Locale(identifier: "ko_KR")))
    }
}
