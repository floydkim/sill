import AppKit
import SwiftUI
import StreamProtocol

struct ViewerScreen: View {
    @ObservedObject var client: ViewerClient
    let surface: ViewerSurface
    @State private var address = ""
    @State private var code = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "display.2").foregroundStyle(.tint)
                Text("Sill Viewer").font(.headline)
                Spacer()
                Text(client.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if client.busy { ProgressView().controlSize(.small) }
                if client.connected {
                    Picker("Show", selection: Binding(get: { client.source }, set: { client.select($0) })) {
                        Text("Desktop").tag(StreamSource.desktop)
                        ForEach(client.windows) { window in
                            Text("\(window.appName) — \(window.title)").tag(StreamSource.window(window.id))
                        }
                    }.frame(maxWidth: 380)
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
