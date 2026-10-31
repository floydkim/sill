import AppKit
import SwiftUI
import StreamProtocol

struct ViewerScreen: View {
    @ObservedObject var client: ViewerClient
    let surface: ViewerSurface
    @State private var address = ""
    @State private var code = ""
    @State private var showingQuality = false
    @AppStorage("viewer.showScreenList") private var showingScreenList = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "display.2").foregroundStyle(.tint)
                Text("Sill 뷰어").font(.headline)
                Spacer()
                Text(client.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if client.busy { ProgressView().controlSize(.small) }
                if client.connected {
                    if client.hostSettings?.screenLocked == true {
                        Label("Mac 잠김", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button {
                        surface.releaseInput()
                        showingScreenList.toggle()
                    } label: {
                        Label(showingScreenList ? "화면 목록 숨기기" : "화면 목록 보기", systemImage: "rectangle.topthird.inset.filled")
                    }
                    .help(showingScreenList ? "화면 목록을 숨겨 원격 화면을 더 크게 표시합니다." : "화면 목록과 가상 데스크탑 이동 버튼을 표시합니다.")
                    Button { surface.releaseInput(); showingQuality.toggle() } label: {
                        Label("영상 품질", systemImage: "slider.horizontal.3")
                    }
                    .popover(isPresented: $showingQuality) { qualityPanel }
                    Button("연결 해제") { surface.releaseInput(); client.disconnect() }
                } else if client.busy {
                    Button("취소") { client.disconnect() }
                }
            }.padding(12)
            Divider()
            if let error = client.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { client.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("닫기")
                }.padding(12).background(Color.orange.opacity(0.12))
            }
            if client.connected {
                if client.hostSettings?.screenLocked == true {
                    HStack {
                        Label("원격 Mac이 잠겨 있습니다. 앱 영상이 움직여도 입력은 잠금 화면으로 전달됩니다.", systemImage: "lock.fill")
                            .font(.callout)
                        Spacer()
                        Button("잠금 화면 보기") { surface.releaseInput(); client.select(.desktop) }
                    }.padding(12).background(Color.orange.opacity(0.12))
                }
                if showingScreenList {
                    sourceBrowser
                    Divider()
                }
                SurfaceView(surface: surface)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if !client.pictureReady {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("원격 Mac의 영상을 기다리는 중…").foregroundStyle(.secondary)
                            }
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false)
                        }
                    }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("다른 Mac에 연결").font(.largeTitle.bold())
                            Text("원격 Mac에서 Sill을 실행하세요. 아래에서 Mac을 선택한 뒤 원격 Mac에 표시된 페어링 코드를 입력하세요.")
                                .foregroundStyle(.secondary)
                        }
                        if !client.saved.isEmpty {
                            Text("페어링한 Mac").font(.headline)
                            ForEach(client.saved) { host in
                                HStack {
                                    Button { client.connect(host) } label: { Label(host.name, systemImage: "desktopcomputer") }
                                        .disabled(client.busy)
                                    Spacer()
                                    Button("삭제") { client.forget(host) }.buttonStyle(.borderless)
                                }
                            }
                        }
                        HStack {
                            Text("주변 Mac").font(.headline)
                            Spacer()
                            Button("새로 고침") { client.refresh() }.disabled(client.busy)
                        }
                        if client.nearby.isEmpty {
                            Label("아직 Mac을 찾지 못했습니다. 원격 Mac에서 Sill을 실행하고 로컬 네트워크 권한을 확인한 뒤 새로 고침을 누르세요.", systemImage: "wifi")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(client.nearby) { host in
                            Button { client.connect(host) } label: {
                                HStack {
                                    Image(systemName: "laptopcomputer")
                                    Text(host.name)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }.padding(8).frame(maxWidth: .infinity)
                            }.disabled(client.busy)
                        }
                        Divider()
                        Text("주소로 연결").font(.headline)
                        HStack {
                            TextField("Mac 이름 또는 IP:포트", text: $address).onSubmit { connectAddress() }
                            Button("연결") { connectAddress() }.disabled(address.isEmpty || client.busy)
                        }
                        Text("다른 네트워크에서는 원격 Mac의 Sill에서 원격 접속을 켜고 VPN 주소로 연결하세요. 기본 포트는 7455입니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("영상을 클릭하면 키보드 입력을 보낼 수 있습니다. 영상에 포커스가 있는 동안 단축키는 원격 Mac으로 전달됩니다. 종료하려면 위의 연결 해제를 누르세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(32).frame(maxWidth: 650)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .sheet(isPresented: $client.pairing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(client.pairingName) 페어링").font(.title2.bold())
                Text("원격 Mac의 Sill에 표시된 12자리 코드를 입력하세요. 코드가 없으면 원격 Mac에서 Sill → iPhone 또는 iPad 페어링…을 여세요.")
                TextField("0000 0000 0000", text: $code).font(.title.monospacedDigit())
                    .onSubmit { client.pair(code: code) }
                if let error = client.error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Button("취소") { client.disconnect(); code = "" }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if client.busy { ProgressView().controlSize(.small) }
                    Button("페어링") { client.pair(code: code) }.keyboardShortcut(.defaultAction).disabled(client.busy)
                }
            }.padding(24).frame(width: 430)
        }
        .onAppear { client.browse() }
    }

    private var qualityPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("영상 품질").font(.title2.bold())
            if let state = client.hostSettings {
                let settings = state.settings
                VStack(spacing: 12) {
                    Picker("화질", selection: Binding(get: { settings.bitrate }, set: {
                        client.changeSettings(HostSettingsChange(bitrate: $0))
                    })) {
                        ForEach(QualityPreset.allCases) { Text($0.koreanTitle).tag($0.rawValue) }
                        if QualityPreset(rawValue: settings.bitrate) == nil {
                            Text(QualityPreset.koreanTitle(forBitrate: settings.bitrate)).tag(settings.bitrate)
                        }
                    }
                    Picker("해상도", selection: Binding(get: { settings.captureScale }, set: {
                        client.changeSettings(HostSettingsChange(captureScale: $0))
                    })) {
                        Text("레티나 (2×)").tag(2.0)
                        Text("표준 (1×)").tag(1.0)
                        if !SettingsChoices.captureScale.contains(settings.captureScale) {
                            Text("사용자 설정 (\(settings.captureScale.formatted())×)").tag(settings.captureScale)
                        }
                    }
                    Picker("최대 프레임 속도", selection: Binding(get: { settings.maxFPS }, set: {
                        client.changeSettings(HostSettingsChange(maxFPS: $0))
                    })) {
                        ForEach(SettingsChoices.maxFPS, id: \.self) { Text("\($0) fps").tag($0) }
                        if !SettingsChoices.maxFPS.contains(settings.maxFPS) {
                            Text("사용자 설정 — \(settings.maxFPS) fps").tag(settings.maxFPS)
                        }
                    }
                    Toggle("인코딩 속도 우선", isOn: Binding(get: { settings.prioritizeSpeed }, set: {
                        client.changeSettings(HostSettingsChange(prioritizeSpeed: $0))
                    }))
                    Toggle("가상 디스플레이", isOn: Binding(get: { settings.virtualDisplay }, set: {
                        client.changeSettings(HostSettingsChange(virtualDisplay: $0))
                    }))
                    .disabled(!state.virtualDisplayAvailable && !settings.virtualDisplay)
                    .help("영상을 전송하는 동안 선택한 앱 창을 원격 Mac의 보이지 않는 디스플레이로 옮깁니다.")
                }.disabled(client.settingsPending)
                Text("가상 디스플레이를 켜면 선택한 앱 창을 보이지 않는 디스플레이로 옮깁니다. 끄면 원래 디스플레이의 창을 보여줍니다. 변경 시 영상 전송이 잠시 재시작됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if let note = state.virtualDisplayNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                } else if !state.virtualDisplayAvailable && !settings.virtualDisplay {
                    Text("이 원격 Mac에서는 가상 디스플레이를 사용할 수 없습니다.").font(.caption).foregroundStyle(.secondary)
                }
                if client.settingsPending {
                    HStack { ProgressView().controlSize(.small); Text("원격 Mac의 응답을 기다리는 중…") }
                        .font(.caption)
                } else if let notice = client.settingsNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if let stream = state.stream {
                    Text("전송 중: \(stream.width) × \(stream.height) · \(stream.fps) fps · \(stream.mbps) Mbps")
                        .font(.caption.monospacedDigit())
                    if case .window = client.source {
                        Text(stream.onVirtualDisplay ? "가상 디스플레이의 창을 전송하고 있습니다." : "원래 디스플레이의 창을 전송하고 있습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("전송 중인 영상이 없습니다.").font(.caption).foregroundStyle(.secondary)
                }
                if state.softwareEncoder {
                    Text("원격 Mac이 소프트웨어 인코딩을 사용 중이므로 해상도와 프레임 속도가 제한될 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let away = state.away {
                    Text(away.thisConnectionAway ? "외부 접속 화질을 변경합니다 (VPN / 원격 접속)." : "내부 접속 화질을 변경합니다 (로컬 네트워크).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("화질의 비트레이트는 60 fps 기준이며, 120 fps에서는 두 배를 사용합니다. 실제 프레임 속도는 이 Mac의 디스플레이와 원격 Mac에 따라서도 달라집니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(state.persistent ? "변경 사항은 원격 Mac에 저장되며 다른 연결된 기기에도 영향을 줄 수 있습니다." : "변경 사항은 원격 Mac의 현재 실행 중에만 적용됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("원격 Mac의 영상 설정을 기다리는 중입니다. 원격 Mac이 설정 기능을 지원하면 조절 항목이 표시됩니다.")
                    .foregroundStyle(.secondary)
            }
        }.padding(20).frame(width: 380)
    }

    private var sourceBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("앱 창").font(.subheadline.bold())
                Spacer()
                Button {
                    surface.releaseInput()
                    client.desktopGesture(TrackpadGesture.swipeRight)
                } label: { Label("이전 데스크탑", systemImage: "chevron.left") }
                Button {
                    surface.releaseInput()
                    client.desktopGesture(TrackpadGesture.swipeUp)
                } label: { Label("미션 컨트롤", systemImage: "rectangle.3.group") }
                Button {
                    surface.releaseInput()
                    client.desktopGesture(TrackpadGesture.swipeLeft)
                } label: { Label("다음 데스크탑", systemImage: "chevron.right") }
            }
            .controlSize(.small)
            .disabled(!client.supportsSpaces)
            .help(client.supportsSpaces
                  ? "원격 Mac의 가상 데스크탑을 이동합니다. 앱 창 카드는 현재 데스크탑에 따라 바뀝니다."
                  : "이 원격 Mac은 가상 데스크탑 이동 기능을 제공하지 않습니다.")
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        if client.displays.isEmpty {
                            sourceCard(.desktop, title: "데스크탑", subtitle: "원격 Mac이 선택한 모니터")
                                .id(StreamSource.desktop)
                        } else {
                            ForEach(client.displays) { display in
                                sourceCard(.desktop, title: display.name,
                                           subtitle: "\(display.isMain ? "주 모니터 · " : "")\(display.width) × \(display.height)", displayID: display.id)
                                    .id("display-\(display.id)")
                            }
                        }
                        ForEach(client.windows) { window in
                            sourceCard(.window(window.id), title: window.appName,
                                       subtitle: window.title, image: client.thumbnails[window.id])
                                .id(StreamSource.window(window.id))
                        }
                    }.padding(3)
                }
                .frame(height: 145)
                .onChange(of: client.source) { _, source in
                    withAnimation {
                        if source == .desktop, let id = client.desktopDisplayID {
                            proxy.scrollTo("display-\(id)", anchor: .center)
                        } else {
                            proxy.scrollTo(source, anchor: .center)
                        }
                    }
                }
                .onChange(of: client.desktopDisplayID) { _, id in
                    if client.source == .desktop, let id {
                        withAnimation { proxy.scrollTo("display-\(id)", anchor: .center) }
                    }
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func sourceCard(_ source: StreamSource, title: String, subtitle: String,
                            image: NSImage? = nil, displayID: UInt32? = nil) -> some View {
        let selected = client.source == source && (displayID == nil || client.desktopDisplayID == displayID)
        return Button {
            surface.releaseInput()
            if let displayID { client.selectDisplay(displayID) } else { client.select(source) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.black)
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: source == .desktop ? "desktopcomputer" : "macwindow")
                            .font(.system(size: 26)).foregroundStyle(.gray)
                    }
                }
                .frame(height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                HStack(spacing: 4) {
                    Text(title).font(.caption.bold()).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
                Text(subtitle.isEmpty ? title : subtitle)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8).frame(width: 180)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(source == .desktop && displayID == nil
              ? "이 원격 Mac은 모니터 선택 없이 데스크탑 영상 하나를 제공합니다. 앱 카드로 개별 창을 볼 수 있습니다."
              : (subtitle.isEmpty ? title : "\(title) — \(subtitle)"))
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title) — \(subtitle)")
        .accessibilityValue(selected ? "선택됨" : "")
    }

    private func connectAddress() { if !address.isEmpty && !client.busy { client.connectAddress(address) } }
}

private struct SurfaceView: NSViewRepresentable {
    let surface: ViewerSurface
    func makeNSView(context: Context) -> ViewerSurface { surface }
    func updateNSView(_ nsView: ViewerSurface, context: Context) {}
}

final class ViewerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var client: ViewerClient?
    private var surface: ViewerSurface?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Sill 뷰어"
        window.delegate = self
        window.contentView = NSHostingView(rootView:
            VStack(spacing: 16) {
                ProgressView()
                Text("보안 연결을 준비하는 중…")
                Text("macOS가 키체인 접근을 요청하면 Sill 뷰어가 인증 정보를 사용할 수 있도록 허용하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        installMenu()
        // Keychain can wait for user interaction; the window must already be usable.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let client = ViewerClient()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let surface = ViewerSurface(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
                surface.bind(client)
                self.client = client
                self.surface = surface
                window.contentView = NSHostingView(rootView: ViewerScreen(client: client, surface: surface))
            }
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Sill 뷰어 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Sill 뷰어 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app
        menu.addItem(item)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    func windowWillClose(_ notification: Notification) { surface?.releaseInput(); client?.disconnect() }
    func applicationWillTerminate(_ notification: Notification) { surface?.releaseInput(); client?.disconnect() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
