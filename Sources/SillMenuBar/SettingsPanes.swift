import AppKit
import Combine
import SwiftUI
import SillHostCore
import StreamProtocol

/// One Settings tab: a grouped Form, 520 pt wide. The controls bind straight to
/// `settings.config`, whose didSet is the one path to the host (see HostSettings).
struct SettingsPane: View {
    let tab: SettingsTab
    let model: AppModel
    /// The previews (DebugHooks): General's update section in this state instead of the live one,
    /// so a render does not depend on what an earlier run stored.
    var previewUpdates: UpdatePolicy.Pane?
    /// …and its clipboard section with macOS's answer as given, never read from this Mac.
    var previewClipboardAccess: ClipboardPolicy.MacAccess?
    /// …and what the macOS firewall does as given (FirewallRule), never asked.
    var previewFirewall: FirewallRule.Verdict?

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPane(model: model, settings: model.settings, previewUpdates: previewUpdates,
                                       previewClipboardAccess: previewClipboardAccess, previewFirewall: previewFirewall)
            case .devices: LiveDevicesPane(model: model, settings: model.settings)
            case .streaming: StreamingPane(model: model, settings: model.settings)
            case .virtualDisplay: VirtualDisplayPane(model: model, settings: model.settings)
            case .permissions: PermissionsPane(model: model)
            case .remoteAccess: LiveRemoteAccessPane(model: model, settings: model.settings)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        // Permissions and the login item change behind Sill's back, in System Settings. Re-read
        // them once a second, only while this tab is on screen, and when Sill becomes active; an
        // idle Sill with Settings closed wakes for nothing. The Devices and Remote Access panes
        // follow the host's status, which is pushed, so they poll nothing.
        .task(id: model.visibleSettingsTab == tab) {
            // General on screen: whether the macOS firewall blocks Sill, asked again (FirewallCheck).
            if model.visibleSettingsTab == tab, tab == .general { model.coordinator?.checkFirewall() }
            guard model.visibleSettingsTab == tab, tab != .streaming, tab != .devices, tab != .remoteAccess else { return }
            while !Task.isCancelled {
                model.permissions.refresh()
                model.loginItem.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.permissions.refresh()
            model.loginItem.refresh()
            // Back from Terminal with the command run: General's firewall line follows.
            if model.visibleSettingsTab == tab, tab == .general { model.coordinator?.checkFirewall() }
        }
    }
}

/// Footer text the way System Settings sets it: small, secondary, from the leading edge.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An orange problem line with its sign.
struct Warning: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A system error message inside a sentence of ours: without its own full stop.
func withoutFullStop(_ text: String) -> String {
    text.hasSuffix(".") ? String(text.dropLast()) : text
}

// MARK: General

private struct GeneralPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings
    var previewUpdates: UpdatePolicy.Pane?
    var previewClipboardAccess: ClipboardPolicy.MacAccess?
    var previewFirewall: FirewallRule.Verdict?

    private static let runsFromApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")

    var body: some View {
        Form {
            Section {
                Toggle("로그인 시 실행", isOn: Binding(get: { model.loginItem.isOn }, set: { model.loginItem.set($0) }))
                    .disabled(!model.loginItem.available)
                if !model.loginItem.available {
                    Footnote("Sill 앱으로 실행할 때 사용할 수 있습니다.")
                } else if model.loginItem.needsApproval {
                    LabeledContent("승인 대기 중") {
                        Button("시스템 설정에서 승인…") { model.loginItem.openSystemSettings() }
                    }
                }
                if let error = model.loginItem.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                LabeledContent("실행 경로") {
                    Text(Bundle.main.bundlePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if !Self.runsFromApplications {
                    Label("로그인 항목과 권한은 이 Sill 앱에 적용됩니다. 응용 프로그램 폴더에 앱 하나만 보관하세요.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                LabeledContent("네트워크에 표시되는 이름") { Text(networkName) }
            } footer: {
                HStack(spacing: 4) {
                    Text("이 Mac의 이름입니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("공유 설정에서 변경…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.footnote)
                    Spacer(minLength: 0)
                }
            }
            // Beside the name devices see: the macOS firewall keeping them out (FirewallRule), only
            // while it does.
            if let firewall = previewFirewall ?? model.coordinator?.status.snapshot.firewall, firewall.blocksDevices {
                FirewallSection(verdict: firewall)
            }
            // How devices reach this Mac, so beside its name on the network. Applies at once without
            // restarting the stream (the listener is replaced); enabled in test pattern mode too,
            // where it is saved and changes only the listener.
            Section {
                Toggle("직접 무선 연결", isOn: $settings.config.directWireless)
            } footer: {
                Footnote("AirDrop처럼 같은 Wi‑Fi에 연결하지 않아도 가까이 있는 iPhone과 iPad에서 이 Mac에 접속할 수 있습니다. 켜 두면 Wi‑Fi가 네트워크 채널을 주기적으로 벗어나 영상이 끊길 수 있습니다. 근처의 Sill 사용자에게 이 Mac이 표시되며, ‘페어링 필수’를 끄지 않은 한 페어링한 기기만 연결할 수 있습니다.")
            }
            // The clipboard both ways (HostClipboard): at once, no restart. Each device has its own
            // switch too. macOS's answer is read with the permissions (once a second while this pane
            // shows, and when Sill becomes active), never in a preview.
            Section {
                Toggle("원격 사용 중 이 Mac의 화면 가리기", isOn: $settings.config.hideLocalScreen)
                    .disabled(model.synthetic)
                if let problem = model.coordinator?.status.snapshot.privacyCurtainProblem {
                    Warning(problem)
                }
            } footer: {
                Footnote("기기가 연결된 동안 물리 모니터를 가립니다. 마지막 연결이 끊기거나 이 설정을 끄면 Mac을 잠근 뒤 가림막을 제거합니다. Control–Option–Command–B를 누르면 현재 연결 동안 화면을 표시합니다. 포인터는 보일 수 있으며, Sill을 강제 종료하면 가림막이 사라집니다.")
            }
            ClipboardSection(shareClipboard: $settings.config.shareClipboard,
                             access: previewClipboardAccess ?? model.permissions.clipboardAccess,
                             allow: { model.permissions.allowClipboard() })
            if let preview = previewUpdates {
                UpdatesSection(pane: preview, automatic: .constant(true))
            } else {
                UpdatesSection(pane: model.updates.pane, automatic: $settings.updateCheck,
                               actions: UpdatesSection.Actions(checkNow: { model.updates.checkNow() },
                                                               openRelease: { NSWorkspace.shared.open($0) }))
            }
            Section {
                HStack {
                    Button("로그 보기…") { model.showLog?() }
                    Button("로그 파일 보기") {
                        if let url = HostLog.shared.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .disabled(HostLog.shared.fileURL == nil)
                }
            }
            Section {
                // A way out when the status item is hidden (a crowded menu bar, the notch).
                Button("Sill 종료") { NSApp.terminate(nil) }
            } footer: {
                Footnote("Sill \(AppModel.version) (\(AppModel.build)). 무료 오픈 소스 소프트웨어입니다.")
            }
        }
    }

    private var networkName: String {
        let snapshot = model.coordinator?.status.snapshot ?? HostStatusSnapshot()
        switch snapshot.network {
        case .advertising(let name): return "“\(name)”"
        case .notAdvertised: return "네트워크에 표시하지 않음(테스트 패턴 모드)"
        case .failed: return "표시할 수 없음(연결 수신 실패)"
        case .waiting: return "네트워크 연결 대기 중"
        case .starting, .registering: return "등록 중…"
        }
    }
}

// MARK: Firewall

/// The macOS firewall keeps devices out (FirewallRule; a user's report of 2026-10-29), in the
/// Permissions pane's style: what it blocks and why that matters, then the Terminal command that
/// unblocks Sill, the running executable's path in it, with Copy; or, for Block all incoming
/// connections, where to turn it off. Nothing while the firewall lets devices in. Sill never runs the
/// command itself (it needs an administrator). Drawn alone in the previews in each verdict.
struct FirewallSection: View {
    let verdict: FirewallRule.Verdict
    @State private var copied = false

    var body: some View {
        if let line = FirewallRule.Copy.paneLine(verdict) {
            let command = FirewallRule.Copy.command(verdict)
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        if let command {
                            Button(copied ? "복사됨" : "복사") { copy(command) }
                                .help("터미널에 붙여넣을 명령어 복사")
                        }
                    }
                } label: {
                    Text("방화벽")
                    Text(line)
                }
                if let lines = FirewallRule.Copy.commandLines(verdict) {
                    // A line for the tool and one for each option, never "--" over "unblockapp".
                    Text(verbatim: lines.joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(command ?? "")
                }
            }
        }
    }

    /// The command onto the clipboard, and "복사됨" on the button for 2 s (VoiceOver hears it).
    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        AccessibilityNotification.Announcement("복사됨").post()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

// MARK: Clipboard

/// Share clipboard with devices (HostClipboard, docs/clipboard-plan.md): the switch and its footnote,
/// and while the switch is on and macOS does not allow every read Sill makes on its own
/// (ClipboardPolicy.MacAccess), why what is copied here stays on this Mac and the way to allow it.
/// Drawn alone in the previews in each of macOS's answers (DebugHooks).
struct ClipboardSection: View {
    @Binding var shareClipboard: Bool
    let access: ClipboardPolicy.MacAccess
    var allow: () -> Void = {}

    private var accessWarning: String? {
        switch access {
        case .allowed: return nil
        case .notAsked, .asks: return "macOS가 Sill의 클립보드 읽기 전에 승인을 요구하므로, 이 Mac에서 복사한 내용이 다른 기기로 전송되지 않습니다."
        case .denied: return "macOS가 Sill의 클립보드 읽기를 허용하지 않아, 이 Mac에서 복사한 내용이 다른 기기로 전송되지 않습니다."
        }
    }

    private var accessHint: String? {
        switch access {
        case .allowed: return nil
        case .notAsked:
            return "‘시스템 설정에서 허용’을 누르면 macOS에서 Sill의 접근을 한 번 묻습니다. 이어서 열리는 개인정보 보호 및 보안의 ‘다른 앱에서 붙여넣기’에서 Sill을 허용으로 설정하세요. 기기에서 ‘붙여넣기’로 보낸 텍스트는 계속 받을 수 있습니다."
        case .asks, .denied:
            return "개인정보 보호 및 보안의 ‘다른 앱에서 붙여넣기’에서 Sill을 허용으로 설정하세요. 기기에서 ‘붙여넣기’로 보낸 텍스트는 계속 받을 수 있습니다."
        }
    }

    var body: some View {
        Section {
            Toggle("기기와 클립보드 공유", isOn: $shareClipboard)
            if shareClipboard, let warning = accessWarning {
                VStack(alignment: .leading, spacing: 6) {
                    Warning(warning)
                    if let hint = accessHint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("시스템 설정에서 허용…", action: allow)
                }
            }
        } footer: {
            Footnote("이 Mac에서 복사한 텍스트를 연결된 iPhone이나 iPad에 붙여넣을 수 있습니다. 기기에서 ‘붙여넣기’로 보낸 텍스트는 이 Mac의 클립보드에 저장됩니다.")
        }
    }
}

// MARK: Updates

/// Settings › General's update check: the automatic switch, the line (what the last check found, or
/// why Sill cannot check), Open Release Page… while a newer release is offered, and Check Now. Plain
/// values in, so the previews draw every state. Errors show here and in the log, never in an alert.
struct UpdatesSection: View {
    struct Actions {
        var checkNow: () -> Void = {}
        var openRelease: (URL) -> Void = { _ in }
    }

    let pane: UpdatePolicy.Pane
    @Binding var automatic: Bool
    var actions = Actions()

    var body: some View {
        Section {
            Toggle("자동으로 업데이트 확인", isOn: $automatic)
            LabeledContent {
                HStack(spacing: 8) {
                    if let url = pane.releasePage {
                        Button("릴리즈 페이지 열기…") { actions.openRelease(url) }
                    }
                    Button("지금 확인") { actions.checkNow() }
                        .disabled(!pane.canCheck)
                }
            } label: {
                Text(pane.line)
                    .foregroundStyle(pane.failed ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // VoiceOver hears Check Now's result, which arrives after the click.
            .onChange(of: pane.resultID) { _, _ in
                AccessibilityNotification.Announcement(pane.line).post()
            }
        } footer: {
            Footnote(UpdatePolicy.footnote)
        }
    }
}

// MARK: Streaming

private struct StreamingPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings

    var body: some View {
        Form {
            Section {
                Picker("최대 프레임률", selection: $settings.config.maxFPS) {
                    Text("60 fps").tag(60)
                    Text("120 fps").tag(120)
                }
                .pickerStyle(.segmented)
                Picker("영상 품질", selection: $settings.config.bitrate) {
                    ForEach(QualityPreset.allCases) { Text($0.koreanTitle).tag($0.rawValue) }
                    if QualityPreset(rawValue: settings.config.bitrate) == nil {
                        Text(QualityPreset.koreanTitle(forBitrate: settings.config.bitrate)).tag(settings.config.bitrate)
                    }
                }
                Picker("해상도", selection: $settings.config.captureScale) {
                    Text("레티나").tag(CGFloat(2))
                    Text("표준").tag(CGFloat(1))
                }
            } footer: {
                Footnote("각 기기의 화면 주사율에 맞춰 이 한도까지 전송합니다. 영상 품질은 60 fps 기준이며, 120 fps에서는 비트레이트가 두 배입니다. \(QualityPreset.koreanFastLinkNote) 변경 즉시 적용되며 영상이 잠시 다시 시작됩니다.")
            }
            // Away from home (docs/remote-bundle-plan.md §5): its own quality, which a device away
            // sets too; the menu's Quality and Resolution stay the home ones.
            Section {
                Picker("영상 품질", selection: $settings.config.awayBitrate) {
                    ForEach(QualityPreset.allCases) { Text($0.koreanTitle).tag($0.rawValue) }
                    if QualityPreset(rawValue: settings.config.awayBitrate) == nil {
                        Text(QualityPreset.koreanTitle(forBitrate: settings.config.awayBitrate)).tag(settings.config.awayBitrate)
                    }
                }
                Picker("해상도", selection: $settings.config.awayCaptureScale) {
                    Text("레티나").tag(CGFloat(2))
                    Text("표준").tag(CGFloat(1))
                }
            } header: {
                Text("외부 네트워크")
            } footer: {
                Footnote("연결된 모든 기기가 VPN이나 인터넷을 통해 외부에서 접속하면 이 설정으로 전송합니다. 느린 연결에서 내부 네트워크용 고화질로 시작하는 것을 방지합니다. 외부 기기에서 품질을 바꾸면 이 설정에만 적용되며 위의 영상 품질과 해상도는 바뀌지 않습니다."
                         + (model.coordinator?.status.snapshot.away == true ? " 현재 이 설정으로 전송 중입니다." : ""))
            }
            Section {
                Toggle("인코딩 속도 우선", isOn: $settings.config.prioritizeSpeed)
            } footer: {
                Footnote("Mac에 부하가 높을 때 화질을 낮춰 지연을 줄입니다.")
            }
            // The Mac's sound (docs/audio-plan.md §6), a beta: its switch and its footnote say so. A device's
            // Settings panel turns it on and off too, for every device, and mutes it for that device alone
            // (Q8 as Noah revised it on 2026-10-27).
            Section {
                Toggle("오디오 전송(베타)", isOn: $settings.config.sendAudio)
                if settings.config.sendAudio, let problem = model.coordinator?.status.snapshot.audio?.problem {
                    Warning("Sill 오디오 전송 문제: \(problem). 영상에는 영향이 없습니다.")
                }
            } footer: {
                Footnote("베타 기능입니다. 선택한 윈도우가 속한 앱의 소리를 전송하며, 데스크탑을 선택하면 모든 앱의 소리를 전송합니다. Mac에서도 소리가 계속 재생됩니다. 연결된 iPhone이나 iPad의 Sill 설정에서도 켜고 끌 수 있으며, 해당 기기에서만 음소거할 수도 있습니다. 소리는 녹음하지 않습니다.")
            }
            if let snapshot = model.coordinator?.status.snapshot, snapshot.softwareEncoder {
                Section {
                    Label(snapshot.hardwareEncoderStuck
                          ? "하드웨어 인코더가 응답하지 않아 소프트웨어 인코더를 사용합니다. 표준 해상도에서 최대 60 fps로 전송합니다. Mac을 재시동하면 복구됩니다."
                          : "하드웨어 인코더가 사용 중이거나 응답하지 않아 소프트웨어 인코더를 사용합니다. 표준 해상도에서 최대 60 fps로 전송하며, 복구되면 자동으로 하드웨어 인코더로 전환합니다.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: Virtual Display

private struct VirtualDisplayPane: View {
    let model: AppModel
    @Bindable var settings: HostSettings
    @State private var retrying = false

    var body: some View {
        let snapshot = model.coordinator?.status.snapshot ?? HostStatusSnapshot()
        Form {
            Section {
                Toggle("가상 디스플레이에서 전송", isOn: $settings.config.virtualDisplay)
            } footer: {
                Footnote("선택한 윈도우를 기기 전용 가상 디스플레이로 이동합니다. 다른 윈도우에 가려져도 계속 갱신되며, 기기의 배율에 맞춰 텍스트를 그립니다. 전송 중에는 윈도우가 이 화면에서 사라지고, 전송을 중단하거나 Sill을 종료하면 돌아옵니다.")
            }
            Section {
                LabeledContent("상태") {
                    HStack(spacing: 8) {
                        Text(statusText(snapshot))
                            .multilineTextAlignment(.trailing)
                        if canRetry(snapshot) {
                            Button("다시 시도") {
                                retrying = true
                                Task { @MainActor in
                                    await model.coordinator?.retryVirtualDisplay()
                                    retrying = false
                                }
                            }
                            .disabled(retrying || model.coordinator == nil)
                        }
                    }
                }
                if settings.config.virtualDisplay, let failure = snapshot.lastStageFailure {
                    LabeledContent("마지막 윈도우") {
                        Text("원래 위치에서 전송 중: \(failure)").multilineTextAlignment(.trailing)
                    }
                }
            } footer: {
                Footnote("macOS 비공개 인터페이스(CGVirtualDisplay)를 사용합니다. macOS 업데이트로 작동하지 않으면 윈도우를 원래 위치에서 전송합니다.")
            }
        }
    }

    private func statusText(_ s: HostStatusSnapshot) -> String {
        let sr = model.permissions.screenRecording, ax = model.permissions.accessibility
        if s.virtualDisplayAPIMissing, let problem = s.virtualDisplayProblem {
            return "이 macOS 버전에서 사용할 수 없음: \(problem)"
        }
        if !sr && !ax { return "화면 기록 및 손쉬운 사용 권한 필요" }
        if !ax { return "손쉬운 사용 권한 필요" }
        if !sr { return "화면 기록 권한 필요" }
        if let problem = s.virtualDisplayProblem { return "이번 실행에서 사용 중지됨: \(problem)" }
        return "사용 가능"
    }

    /// A run-level disable (the system removed the display too often) can be retried; a missing
    /// API or permission cannot.
    private func canRetry(_ s: HostStatusSnapshot) -> Bool {
        s.virtualDisplayProblem != nil && !s.virtualDisplayAPIMissing && model.permissions.allGranted
    }
}

// MARK: Permissions

private struct PermissionsPane: View {
    let model: AppModel

    var body: some View {
        let permissions = model.permissions
        let network = model.coordinator?.status.snapshot.network
        Form {
            Section {
                PermissionRow(title: "화면 기록", allowed: permissions.screenRecording,
                              // Not "on this network": a device connected over Direct Wireless shares none.
                              explanation: "iPhone이나 iPad에서 선택한 윈도우와 오디오 전송을 켰을 때의 소리를 캡처합니다. 영상과 소리는 기록하거나 저장하지 않고 기기로 바로 전송합니다.",
                              button: model.settings.askedScreenRecording ? "시스템 설정 열기…" : "허용…") {
                    permissions.requestScreenRecording()
                }
                PermissionRow(title: "손쉬운 사용", allowed: permissions.accessibility,
                              explanation: "iPhone이나 iPad에서 이 Mac을 클릭하고 스크롤하며 입력할 수 있게 합니다. Sill이 전송할 윈도우의 위치와 크기를 조정하는 데도 필요합니다.",
                              button: model.settings.askedAccessibility ? "시스템 설정 열기…" : "허용…") {
                    permissions.requestAccessibility()
                }
            } footer: {
                Footnote("Sill 앱 자체에 권한을 허용해야 합니다. SillHost 명령줄 도구를 위해 터미널에 허용한 권한은 이 앱에 적용되지 않습니다.")
            }
            if permissions.relaunchSuggested, !permissions.screenRecording {
                Section {
                    LabeledContent("Sill을 다시 실행하면 화면 기록 권한이 적용됩니다.") {
                        Button(permissions.canRelaunch ? "Sill 다시 실행" : "Sill 종료") { permissions.relaunch() }
                    }
                }
            }
            if Self.networkNeedsHelp(network) {
                Section {
                    LabeledContent {
                        Button("로컬 네트워크 설정 열기…") { permissions.openPrivacyPane("Privacy_LocalNetwork") }
                    } label: {
                        Text("로컬 네트워크")
                        Text("iPhone이나 iPad에서 이 Mac을 찾을 수 없다면 개인정보 보호 및 보안 › 로컬 네트워크에서 Sill을 허용하세요.")
                    }
                }
            }
            if permissions.allGranted {
                Section {
                    Label("준비가 끝났습니다. iPhone이나 iPad에서 Sill을 여세요.", systemImage: "checkmark.seal.fill")
                }
            }
        }
    }

    private static func networkNeedsHelp(_ network: HostStatusSnapshot.Network?) -> Bool {
        switch network {
        case .waiting, .failed: return true
        default: return false
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let allowed: Bool
    let explanation: String
    let button: String
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if allowed {
                Label("허용됨", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button(button, action: action)
                }
            }
        } label: {
            Text(title)
            Text(explanation)
        }
    }
}
