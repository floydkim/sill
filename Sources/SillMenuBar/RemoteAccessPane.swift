import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// Settings › Remote Access, live: the host's remote status (pushed, so nothing polls) and the
/// app's settings, with the model's actions.
struct LiveRemoteAccessPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        RemoteAccessPane(status: model.coordinator?.status.snapshot.remote ?? RemoteStatus(),
                         remoteAccess: $settings.config.remoteAccess,
                         internetAccess: $settings.config.internetAccess,
                         port: settings.config.remotePort,
                         addressName: settings.remoteAddressName,
                         actions: RemoteAccessPane.Actions(
                             setPort: { settings.config.remotePort = $0 },
                             setAddressName: { settings.remoteAddressName = $0 },
                             showDevices: { model.showSettings?(.devices) }))
    }
}

/// The Remote Access pane (docs/remote-access-plan.md §6.1): the switch, the Mac's addresses and
/// its port, how many devices are paired (the list itself is in Settings › Devices,
/// docs/home-pairing-plan.md §6.2), the internet switch, and sleep. Values in, actions out, so the
/// previews can draw every state. Errors show inline, never in alerts.
struct RemoteAccessPane: View {
    struct Actions {
        var setPort: (Int) -> Void = { _ in }
        var setAddressName: (String) -> Void = { _ in }
        /// Show Devices…: Settings on the Devices tab.
        var showDevices: () -> Void = {}
    }

    let status: RemoteStatus
    @Binding var remoteAccess: Bool
    @Binding var internetAccess: Bool
    /// The configured port (the app's is never 0).
    let port: Int
    /// The address name setting, as saved.
    let addressName: String
    let actions: Actions

    @State private var editingPort = false
    @State private var portText = ""
    @State private var portSaved = false
    @State private var nameText: String?
    @State private var nameProblem: String?

    private var available: Bool { status.identityProblem == nil }
    private var on: Bool { remoteAccess && available }

    var body: some View {
        Form {
            Section {
                Toggle("원격 접속", isOn: $remoteAccess)
                    .disabled(!available)
                if let problem = status.identityProblem {
                    // The system's messages end with a full stop of their own.
                    let reason = problem.hasSuffix(".") ? String(problem.dropLast()) : problem
                    Warning("원격 접속을 사용할 수 없습니다. Sill이 키체인을 사용할 수 없습니다(\(reason)).")
                }
            } footer: {
                Footnote("페어링한 iPhone과 iPad가 다른 네트워크에서 이 Mac에 접속할 수 있게 합니다. Tailscale 같은 VPN이나 공유기의 포트 포워딩을 사용합니다. 페어링하지 않은 기기는 차단하며, 페어링한 기기가 주고받는 모든 데이터는 암호화합니다.")
            }
            if on { addresses }
            pairedDevices
            if on { internet }
            Section {
                LabeledContent {
                    Button("에너지 설정 열기…") { Self.openEnergySettings() }
                } label: {
                    Text("잠자기")
                    Text("Mac이 잠자기 상태이면 접속할 수 없습니다. 외부에서 기기가 연결된 동안 Sill이 자동 잠자기를 방지합니다.")
                }
            }
        }
    }

    // MARK: Addresses

    @ViewBuilder private var addresses: some View {
        let rows = Self.addressRows(status.addresses)
        Section {
            switch status.listener {
            case .portInUse(let p):
                LabeledContent {
                    Button("변경…") { startEditingPort() }
                } label: {
                    Warning("다른 앱이 포트 \(p)를 사용 중이어서 원격 접속을 받을 수 없습니다. Sill이 30초마다 다시 시도합니다.")
                }
            case .failed(let error):
                Warning("원격 접속을 시작할 수 없습니다(\(error)). Sill이 30초마다 다시 시도합니다.")
            case .off, .listening:
                EmptyView()
            }
            ForEach(rows) { row in
                LabeledContent {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.primary).textSelection(.enabled)
                            if !row.others.isEmpty {
                                Text(row.others.joined(separator: " · "))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        CopyButton(text: row.primary, spoken: "\(StatusText.koreanRoute(row.label)) 주소 복사")
                    }
                } label: {
                    Text(StatusText.koreanRoute(row.label))
                    if row.lan {
                        Text("현재 네트워크의 주소입니다. 공유기의 WireGuard처럼 이 네트워크에 접속할 수 있는 VPN과 함께 사용하세요.")
                    }
                }
            }
            ForEach(status.vpnDown, id: \.self) { name in
                Text("\(name) — 연결되지 않음").foregroundStyle(.secondary)
            }
            if !rows.contains(where: { $0.vpn }) && status.vpnDown.isEmpty {
                Text("이 Mac에 연결된 VPN이 없습니다. 이 Mac과 iPhone 또는 iPad에 Tailscale 같은 VPN을 설치하거나, 아래에서 인터넷 연결을 허용하세요.")
                    .foregroundStyle(.secondary)
            }
            portRow
        } header: {
            Text("주소")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(status.vpnDown, id: \.self) { name in
                    Footnote("\(name)에 연결되기 전에는 기기가 해당 경로로 이 Mac에 접속할 수 없습니다.")
                }
                Footnote("기기는 페어링할 때 이 주소를 저장하고, 연결할 때마다 최신 주소로 갱신합니다.")
            }
        }
    }

    @ViewBuilder private var portRow: some View {
        if editingPort {
            let problem = Self.portProblem(portText)
            LabeledContent("포트") {
                HStack(spacing: 8) {
                    TextField("포트", text: $portText)
                        .labelsHidden()
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .onSubmit { savePort() }
                        .onExitCommand { editingPort = false }
                    Button("저장") { savePort() }
                        .disabled(problem?.blocks ?? false)
                        .keyboardShortcut(.defaultAction)
                    Button("취소") { editingPort = false }
                }
            }
            if let problem {
                if problem.blocks { Warning(problem.message) } else { Text(problem.message).foregroundStyle(.secondary) }
            }
        } else {
            LabeledContent("포트") {
                HStack(spacing: 8) {
                    Text(String(port)).monospacedDigit().textSelection(.enabled)
                    Button("변경…") { startEditingPort() }
                }
            }
            if portSaved {
                Text("페어링한 기기는 다음에 같은 네트워크에서 연결할 때 새 포트를 저장합니다.").foregroundStyle(.secondary)
            }
        }
    }

    private func startEditingPort() {
        portText = String(port)
        portSaved = false
        editingPort = true
    }

    private func savePort() {
        if let problem = Self.portProblem(portText), problem.blocks { return }
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)) else { return }
        editingPort = false
        if p != port {
            actions.setPort(p)
            portSaved = true
        }
    }

    /// What is wrong with a port typed into the field: blocking (it cannot be saved), or only a
    /// warning. Nil when it is fine.
    static func portProblem(_ text: String) -> (message: String, blocks: Bool)? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && $0.isNumber }), t.count <= 5, let p = Int(t), (1024...65535).contains(p) else {
            return ("1024~65535 사이의 포트를 입력하세요.", true)
        }
        if p == 5000 || p == 7000 { return ("포트 \(p)는 AirPlay 수신기가 사용합니다. 다른 포트를 선택하세요.", true) }
        if p >= 49152 { return ("49152 이상의 포트는 다른 앱이 언제든 사용할 수 있습니다.", false) }
        return nil
    }

    // MARK: Paired devices

    /// One row: the list, Remove and Pair iPhone or iPad… are in Settings › Devices, since the same
    /// devices connect at home too.
    private var pairedDevices: some View {
        Section {
            LabeledContent("페어링한 기기") {
                HStack(spacing: 8) {
                    Text(status.paired.isEmpty ? "없음" : "\(status.paired.count)").monospacedDigit()
                    Button("기기 보기…") { actions.showDevices() }
                }
            }
        } footer: {
            Footnote("기기 탭에서 페어링한 기기는 원격 접속을 켜 두면 외부에서도 연결할 수 있습니다.")
        }
    }

    // MARK: Internet

    private var internet: some View {
        Section {
            Toggle("인터넷에서 연결 허용", isOn: $internetAccess)
            if internetAccess {
                if let lan = status.lanAddress {
                    LabeledContent {
                        CopyButton(text: lan, spoken: "이 Mac의 주소 복사")
                    } label: {
                        Text("공유기의 TCP 포트 \(String(port))를 이 Mac(\(lan))으로 포워딩하고, 공유기 설정에서 이 Mac에 해당 주소를 고정 할당하세요.")
                    }
                }
                routerRow
                addressNameRow
                if let v6 = status.addresses.first(where: { $0.kind == MacAddress.internet && $0.via == "IPv6" }) {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(v6.host).textSelection(.enabled)
                            CopyButton(text: v6.host, spoken: "IPv6 주소 복사")
                        }
                    } label: {
                        Text("IPv6")
                        Text("공유기가 외부 IPv6 연결을 이 Mac으로 허용해야 작동합니다. 대부분의 공유기는 기본으로 차단합니다.")
                    }
                }
            }
        } header: {
            Text("인터넷")
        } footer: {
            if internetAccess {
                Footnote("인터넷의 누구나 포트 \(String(port))에 연결을 시도할 수 있습니다. Sill은 페어링하지 않은 기기를 차단합니다. 이 설정을 꺼도 공유기 포트는 닫히지 않으므로 포트 포워딩도 삭제하세요.")
            } else {
                Footnote("공유기의 포트 포워딩을 사용할 때만 필요합니다. VPN을 사용하면 더 간단하며 이 Mac을 인터넷에 직접 노출하지 않습니다.")
            }
        }
    }

    @ViewBuilder private var routerRow: some View {
        switch status.router {
        case .off:
            EmptyView()
        case .asking:
            LabeledContent("공유기의 인터넷 주소") { Text("공유기에 확인 중…").foregroundStyle(.secondary) }
        case .address(let a):
            LabeledContent("공유기의 인터넷 주소") {
                HStack(spacing: 8) {
                    Text(a).textSelection(.enabled)
                    CopyButton(text: a, spoken: "공유기의 인터넷 주소 복사")
                }
            }
        case .carrierNAT(let a):
            LabeledContent("공유기의 인터넷 주소") {
                Warning("인터넷 제공업체가 이 주소(\(Self.masked(a)))를 여러 가입자에게 공유하므로 포트 포워딩으로 이 Mac에 접속할 수 없습니다. Tailscale 같은 VPN을 사용하세요.")
            }
        case .doubleNAT:
            LabeledContent("공유기의 인터넷 주소") {
                Warning("공유기 앞에 다른 공유기가 있습니다. 두 공유기 모두에 포트 포워딩을 설정하거나 VPN을 사용하세요.")
            }
        case .noAnswer:
            LabeledContent("공유기의 인터넷 주소") {
                Text("공유기에서 주소를 받지 못했습니다. 공유기 설정에서 확인하세요.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var addressNameRow: some View {
        LabeledContent {
            TextField("주소 이름", text: Binding(get: { nameText ?? addressName }, set: { nameText = $0; nameProblem = nil }),
                      prompt: Text("home.example.net"))
                .labelsHidden()
                .frame(width: 220)
                .onSubmit { saveAddressName() }
        } label: {
            Text("주소 이름(선택 사항)")
            Text("공유기에 동적 DNS 이름이 있다면 입력하세요. 인터넷 주소가 바뀌어도 기기가 이 Mac을 찾을 수 있습니다. 공유기의 외부 포트가 다르다면 이름 뒤에 :포트를 붙이세요.")
        }
        if let nameProblem { Warning(nameProblem) }
    }

    private func saveAddressName() {
        let text = (nameText ?? addressName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { nameProblem = nil; actions.setAddressName(""); return }
        switch AddressParser.parse(text) {
        case .success:
            nameProblem = nil
            actions.setAddressName(text)
        case .failure(.zone):
            nameProblem = "% 뒤의 부분을 제거하세요. 해당 부분은 현재 네트워크에서만 사용할 수 있습니다."
        case .failure:
            nameProblem = "올바른 주소가 아닙니다. home.example.net 또는 home.example.net:17455 형식으로 입력하세요."
        }
    }

    // MARK: Helpers

    /// One row per way in: the service's name, the name devices dial first (a MagicDNS name) and
    /// the addresses behind it. Internet addresses have their own section.
    struct AddressRow: Identifiable {
        var id: String { label }
        var label: String
        var primary: String
        var others: [String]
        var vpn: Bool
        var lan: Bool
    }

    static func addressRows(_ addresses: [MacAddress]) -> [AddressRow] {
        var order: [String] = []
        var byVia: [String: [MacAddress]] = [:]
        for a in addresses where a.kind != MacAddress.internet {
            if byVia[a.via] == nil { order.append(a.via) }
            byVia[a.via, default: []].append(a)
        }
        return order.compactMap { via in
            guard let list = byVia[via] else { return nil }
            let isName: (MacAddress) -> Bool = { a in
                if case .success(let p) = AddressParser.parse(a.host) { return p.kind == .name }
                return false
            }
            let sorted = list.filter(isName) + list.filter { !isName($0) }
            guard let first = sorted.first else { return nil }
            return AddressRow(label: via, primary: first.host, others: sorted.dropFirst().map(\.host),
                              vpn: list.contains { $0.kind == MacAddress.vpn },
                              lan: list.allSatisfy { $0.kind == MacAddress.lan } && via != "This Mac")
        }
    }

    /// "100.72.x.x": a shared carrier address says nothing useful beyond its first half.
    static func masked(_ address: String) -> String {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return address }
        return "\(parts[0]).\(parts[1]).x.x"
    }

    /// Battery on a laptop, Energy on a desktop: one System Settings extension on macOS 27
    /// (/System/Library/ExtensionKit/Extensions/PowerPreferences.appex).
    static func openEnergySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Copy, then "복사됨" for 1.5 s.
private struct CopyButton: View {
    let text: String
    let spoken: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "복사됨" : "복사") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .accessibilityLabel(copied ? "복사됨" : spoken)
    }
}
