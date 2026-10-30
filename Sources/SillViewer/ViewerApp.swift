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
                Text("Sill Viewer").font(.headline)
                Spacer()
                Text(client.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if client.busy { ProgressView().controlSize(.small) }
                if client.connected {
                    Button {
                        surface.releaseInput()
                        showingScreenList.toggle()
                    } label: {
                        Label(showingScreenList ? "Hide Screens" : "Show Screens", systemImage: "rectangle.topthird.inset.filled")
                    }
                    .help(showingScreenList ? "Hide the screen list to enlarge the remote picture." : "Show the screen list and Spaces controls.")
                    Button { surface.releaseInput(); showingQuality.toggle() } label: {
                        Label("Video Settings", systemImage: "slider.horizontal.3")
                    }
                    .popover(isPresented: $showingQuality) { qualityPanel }
                    Button("Disconnect") { surface.releaseInput(); client.disconnect() }
                } else if client.busy {
                    Button("Cancel") { client.disconnect() }
                }
            }.padding(12)
            Divider()
            if let error = client.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { client.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
                }.padding(12).background(Color.orange.opacity(0.12))
            }
            if client.connected {
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
                                Text("Waiting for the host’s picture…").foregroundStyle(.secondary)
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
                            Text("Connect to another Mac").font(.largeTitle.bold())
                            Text("Open Sill on the host Mac. Choose it below, then enter the pairing code shown there.")
                                .foregroundStyle(.secondary)
                        }
                        if !client.saved.isEmpty {
                            Text("Paired Macs").font(.headline)
                            ForEach(client.saved) { host in
                                HStack {
                                    Button { client.connect(host) } label: { Label(host.name, systemImage: "desktopcomputer") }
                                        .disabled(client.busy)
                                    Spacer()
                                    Button("Remove") { client.forget(host) }.buttonStyle(.borderless)
                                }
                            }
                        }
                        HStack {
                            Text("Nearby Macs").font(.headline)
                            Spacer()
                            Button("Refresh") { client.refresh() }.disabled(client.busy)
                        }
                        if client.nearby.isEmpty {
                            Label("No Macs found yet. Open Sill on the host, check Local Network permission, then Refresh.", systemImage: "wifi")
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
                        Text("Connect by address").font(.headline)
                        HStack {
                            TextField("Mac name or IP:port", text: $address).onSubmit { connectAddress() }
                            Button("Connect") { connectAddress() }.disabled(address.isEmpty || client.busy)
                        }
                        Text("For another network, use your VPN address with Remote Access enabled in Sill on the host. The default port is 7455.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Click the picture to send keyboard input. Shortcuts go to the remote Mac while it has focus. Use Disconnect above to leave.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(32).frame(maxWidth: 650)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .sheet(isPresented: $client.pairing) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pair with \(client.pairingName)").font(.title2.bold())
                Text("Enter the 12-digit code from Sill on the host Mac. If needed, open Sill → Pair iPhone or iPad… there.")
                TextField("0000 0000 0000", text: $code).font(.title.monospacedDigit())
                    .onSubmit { client.pair(code: code) }
                if let error = client.error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Button("Cancel") { client.disconnect(); code = "" }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if client.busy { ProgressView().controlSize(.small) }
                    Button("Pair") { client.pair(code: code) }.keyboardShortcut(.defaultAction).disabled(client.busy)
                }
            }.padding(24).frame(width: 430)
        }
        .onAppear { client.browse() }
    }

    private var qualityPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Video Settings").font(.title2.bold())
            if let state = client.hostSettings {
                let settings = state.settings
                VStack(spacing: 12) {
                    Picker("Quality", selection: Binding(get: { settings.bitrate }, set: {
                        client.changeSettings(HostSettingsChange(bitrate: $0))
                    })) {
                        ForEach(QualityPreset.allCases) { Text($0.title).tag($0.rawValue) }
                        if QualityPreset(rawValue: settings.bitrate) == nil {
                            Text(QualityPreset.title(forBitrate: settings.bitrate)).tag(settings.bitrate)
                        }
                    }
                    Picker("Resolution", selection: Binding(get: { settings.captureScale }, set: {
                        client.changeSettings(HostSettingsChange(captureScale: $0))
                    })) {
                        Text("Retina (2×)").tag(2.0)
                        Text("Standard (1×)").tag(1.0)
                        if !SettingsChoices.captureScale.contains(settings.captureScale) {
                            Text("Custom (\(settings.captureScale.formatted())×)").tag(settings.captureScale)
                        }
                    }
                    Picker("Frame Rate Limit", selection: Binding(get: { settings.maxFPS }, set: {
                        client.changeSettings(HostSettingsChange(maxFPS: $0))
                    })) {
                        ForEach(SettingsChoices.maxFPS, id: \.self) { Text("\($0) fps").tag($0) }
                        if !SettingsChoices.maxFPS.contains(settings.maxFPS) {
                            Text("Custom — \(settings.maxFPS) fps").tag(settings.maxFPS)
                        }
                    }
                    Toggle("Prioritize Encoding Speed", isOn: Binding(get: { settings.prioritizeSpeed }, set: {
                        client.changeSettings(HostSettingsChange(prioritizeSpeed: $0))
                    }))
                    Toggle("Virtual Display", isOn: Binding(get: { settings.virtualDisplay }, set: {
                        client.changeSettings(HostSettingsChange(virtualDisplay: $0))
                    }))
                    .disabled(!state.virtualDisplayAvailable && !settings.virtualDisplay)
                    .help("Move the selected app window onto the host’s invisible display while streaming.")
                }.disabled(client.settingsPending)
                Text("Virtual Display on: move the selected app window to an invisible display. Off: show it on its original display. Changing this restarts the stream briefly.")
                    .font(.caption).foregroundStyle(.secondary)
                if let note = state.virtualDisplayNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                } else if !state.virtualDisplayAvailable && !settings.virtualDisplay {
                    Text("Virtual Display is unavailable on this host.").font(.caption).foregroundStyle(.secondary)
                }
                if client.settingsPending {
                    HStack { ProgressView().controlSize(.small); Text("Waiting for host confirmation…") }
                        .font(.caption)
                } else if let notice = client.settingsNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if let stream = state.stream {
                    Text("Streaming: \(stream.width) × \(stream.height) · \(stream.fps) fps · \(stream.mbps) Mbps")
                        .font(.caption.monospacedDigit())
                    if case .window = client.source {
                        Text(stream.onVirtualDisplay ? "Window is streaming from the virtual display." : "Window is streaming from its original display.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No active stream.").font(.caption).foregroundStyle(.secondary)
                }
                if state.softwareEncoder {
                    Text("The host is using software encoding; resolution and frame rate may be limited.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let away = state.away {
                    Text(away.thisConnectionAway ? "Editing Away quality (VPN / remote access)." : "Editing Home quality (local network).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Quality is per 60 fps; 120 fps uses twice the bitrate. The actual rate also depends on this Mac’s display and the host.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(state.persistent ? "Changes are saved on the host and may affect other connected viewers." : "Changes apply to the host’s current session.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Waiting for the host’s video settings. Controls appear when the host reports support.")
                    .foregroundStyle(.secondary)
            }
        }.padding(20).frame(width: 380)
    }

    private var sourceBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Windows").font(.subheadline.bold())
                Spacer()
                Button {
                    surface.releaseInput()
                    client.desktopGesture(TrackpadGesture.swipeRight)
                } label: { Label("Previous Space", systemImage: "chevron.left") }
                Button {
                    surface.releaseInput()
                    client.desktopGesture(TrackpadGesture.swipeUp)
                } label: { Label("Mission Control", systemImage: "rectangle.3.group") }
                Button {
                    surface.releaseInput()
                    client.desktopGesture(TrackpadGesture.swipeLeft)
                } label: { Label("Next Space", systemImage: "chevron.right") }
            }
            .controlSize(.small)
            .disabled(!client.supportsSpaces)
            .help(client.supportsSpaces
                  ? "Navigate Spaces on the host Mac. Window cards follow the current Space."
                  : "This host does not advertise Spaces navigation support.")
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        sourceCard(.desktop, title: "Desktop", subtitle: "Host-selected monitor")
                            .id(StreamSource.desktop)
                        ForEach(client.windows) { window in
                            sourceCard(.window(window.id), title: window.appName,
                                       subtitle: window.title, image: client.thumbnails[window.id])
                                .id(StreamSource.window(window.id))
                        }
                    }.padding(3)
                }
                .frame(height: 145)
                .onChange(of: client.source) { _, source in
                    withAnimation { proxy.scrollTo(source, anchor: .center) }
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func sourceCard(_ source: StreamSource, title: String, subtitle: String,
                            image: NSImage? = nil) -> some View {
        let selected = client.source == source
        return Button {
            surface.releaseInput()
            client.select(source)
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
        .help(source == .desktop
              ? "This host offers one Desktop stream, with no monitor selector. App cards can show individual windows."
              : (subtitle.isEmpty ? title : "\(title) — \(subtitle)"))
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title) — \(subtitle)")
        .accessibilityValue(selected ? "Selected" : "")
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
        window.title = "Sill Viewer"
        window.delegate = self
        window.contentView = NSHostingView(rootView:
            VStack(spacing: 16) {
                ProgressView()
                Text("Preparing secure connections…")
                Text("If macOS asks for Keychain access, allow Sill Viewer to use its identity.")
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
        app.addItem(withTitle: "About Sill Viewer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Sill Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app
        menu.addItem(item)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    func windowWillClose(_ notification: Notification) { surface?.releaseInput(); client?.disconnect() }
    func applicationWillTerminate(_ notification: Notification) { surface?.releaseInput(); client?.disconnect() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
