import AppKit
import Combine
import CryptoKit
import Darwin
import Network
import OSLog
import StreamProtocol

struct NearbyHost: Identifiable {
    let name: String
    let endpoint: NWEndpoint
    let tag: String?
    let encrypted: Bool
    var id: String { String(describing: endpoint) }
}

// Network callbacks and UI state use the main queue. Only the expensive code KDF leaves it.
final class ViewerClient: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var nearby: [NearbyHost] = []
    @Published var saved: [ViewerHost] = []
    @Published var status = "Looking for Macs…" {
        didSet { logger.info("\(self.status, privacy: .public)") }
    }
    @Published var connected = false
    @Published var pictureReady = false
    @Published var busy = false
    @Published var windows: [WindowInfo] = []
    @Published var source: StreamSource = .none
    @Published var pairing = false
    @Published var pairingName = "Mac"
    @Published var error: String? {
        didSet { if let error { logger.error("\(error, privacy: .public)") } }
    }
    var onParameters: ((ParameterSets) -> Void)?
    var onFrame: ((Data, Bool) -> Void)?
    var onClear: (() -> Void)?
    var onCursor: ((NSCursor) -> Void)?
    var onConnected: (() -> Void)?

    private let logger = Logger(subsystem: "local.sill.viewer", category: "connection")
    private var pictureDeadline: DispatchWorkItem?
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var identity: RemoteIdentity?
    private var connection: NWConnection?
    private var reader: MessageReader?
    private var deadline: DispatchWorkItem?
    private var pendingEndpoint: NWEndpoint?
    private var pendingPin: Data?
    private var pendingAddress: String?
    private var pendingService: String?
    private var lastViewport = CGSize(width: 1200, height: 800)
    private var receivedCatalog = false
    private var lastFrameAt = Date()
    private var heartbeat: Timer?

    override init() {
        super.init()
        do {
            identity = try ViewerStore.identity()
            saved = try ViewerStore.hosts()
        } catch { self.error = error.localizedDescription }
    }

    func browse() {
        guard browser == nil else { return }
        logger.notice("Starting Bonjour discovery")
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_sill._tcp.", inDomain: "local.")
    }

    func refresh() {
        browser?.stop()
        browser = nil
        for service in services { service.stopMonitoring(); service.stop() }
        services = []
        nearby = []
        browse()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        guard !services.contains(where: { $0.name == service.name && $0.domain == service.domain && $0.type == service.type }) else { return }
        logger.notice("Discovered \(service.name, privacy: .public); resolving address")
        services.append(service)
        service.delegate = self
        service.startMonitoring()
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        services.removeAll { $0.name == service.name && $0.domain == service.domain && $0.type == service.type }
        updateNearby()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browser === self.browser else { return }
        error = "Discovery unavailable (\(errorDict)). Allow Local Network for Sill Viewer in System Settings → Privacy & Security, then press Refresh."
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        logger.error("Cannot resolve \(sender.name, privacy: .public): \(String(describing: errorDict), privacy: .public)")
    }

    func netServiceDidResolveAddress(_ sender: NetService) { updateNearby() }
    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) { updateNearby() }

    private func updateNearby() {
        func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
            guard address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            // A link-local address may carry an interface scope; compare the IP itself.
            return String(cString: buffer).components(separatedBy: "%")[0]
        }

        var localAddresses = Set<String>()
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0, let first = interfaces {
            defer { freeifaddrs(first) }
            var entry: UnsafeMutablePointer<ifaddrs>? = first
            while let current = entry {
                if let address = current.pointee.ifa_addr, let host = numericHost(address) {
                    localAddresses.insert(host)
                }
                entry = current.pointee.ifa_next
            }
        }

        nearby = services.compactMap { service in
            guard let host = service.hostName, (1...65535).contains(service.port),
                  let port = NWEndpoint.Port(rawValue: UInt16(service.port)) else { return nil }
            let isThisMac = (service.addresses ?? []).contains { data in
                data.withUnsafeBytes { bytes in
                    guard bytes.count >= MemoryLayout<sockaddr>.size, let base = bytes.baseAddress else { return false }
                    let address = base.assumingMemoryBound(to: sockaddr.self)
                    guard Int(address.pointee.sa_len) <= bytes.count, let host = numericHost(address) else { return false }
                    return localAddresses.contains(host)
                }
            }
            guard !isThisMac else { return nil }
            let record = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
            let txt = record.mapValues { String(data: $0, encoding: .utf8) ?? "1" }
            return NearbyHost(name: service.name, endpoint: .hostPort(host: NWEndpoint.Host(host), port: port),
                              tag: txt[RecognitionTag.txtKey], encrypted: HomeDoorTXT.door(txt) != .plain)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        logger.notice("Bonjour found \(self.nearby.count) hosts")
    }

    func connect(_ host: NearbyHost) {
        guard host.encrypted else { fail("Update Sill on \(host.name). This viewer requires an encrypted host."); return }
        let known = saved.first { saved in
            host.tag.map { RecognitionTag.matches($0, recognitionKey: saved.recognitionKey) } ?? false
        }
        prepare(endpoint: host.endpoint, name: host.name, address: nil, service: host.name)
        if let known { session(endpoint: host.endpoint, pin: known.fingerprint) }
        else { askForCode() }
    }

    func connect(_ host: ViewerHost) {
        if let found = nearby.first(where: { $0.tag.map { RecognitionTag.matches($0, recognitionKey: host.recognitionKey) } ?? false }) {
            prepare(endpoint: found.endpoint, name: host.name, address: host.address, service: found.name)
            session(endpoint: found.endpoint, pin: host.fingerprint)
        } else if let address = host.address, let endpoint = endpoint(address) {
            prepare(endpoint: endpoint, name: host.name, address: address, service: host.serviceName)
            session(endpoint: endpoint, pin: host.fingerprint)
        } else if let name = host.serviceName {
            let endpoint = NWEndpoint.service(name: name, type: "_sill._tcp", domain: "local.", interface: nil)
            prepare(endpoint: endpoint, name: host.name, address: nil, service: name)
            session(endpoint: endpoint, pin: host.fingerprint)
        }
    }

    func connectAddress(_ text: String) {
        guard let endpoint = endpoint(text) else { fail("Enter a host name or IP address, optionally followed by :port (default 7455)."); return }
        prepare(endpoint: endpoint, name: text, address: text, service: nil)
        if let known = saved.first(where: { $0.address == text }) { session(endpoint: endpoint, pin: known.fingerprint) }
        else { askForCode() }
    }

    private func endpoint(_ text: String) -> NWEndpoint? {
        guard case .success(let address) = AddressParser.parse(text),
              let port = NWEndpoint.Port(rawValue: UInt16(address.port ?? 7455)) else { return nil }
        return .hostPort(host: NWEndpoint.Host(address.host), port: port)
    }

    private func prepare(endpoint: NWEndpoint, name: String, address: String?, service: String?) {
        disconnect()
        error = nil
        pendingEndpoint = endpoint
        pendingPin = nil
        pendingAddress = address
        pendingService = service
        pairingName = name
    }

    private func askForCode() {
        guard let endpoint = pendingEndpoint else { return }
        dial(endpoint: endpoint, alpn: RemoteTLS.pairingALPN, pin: nil) { [weak self] c, fingerprint in
            guard let self else { return }
            self.pendingPin = fingerprint
            self.send(.pairRequest, Wire.encode(PairRequest(method: "ask", proof: "", name: Host.current().localizedName ?? "Mac", model: "Sill Viewer")))
            self.read(c) { [weak self] header, data in
                guard let self else { return }
                guard header.kind == .pairResult, let result = Wire.decode(PairResult.self, from: data) else {
                    self.fail("Invalid pairing response."); return
                }
                self.closeConnection()
                self.pairing = true
                self.busy = false
                self.status = "Enter the code shown on \(self.pairingName)."
                if result.reason != PairResult.shown {
                    self.error = "On the host Mac, open Sill → Pair iPhone or iPad… to show a code."
                }
            }
        }
    }

    func pair(code text: String) {
        guard case .success(let code) = PairingCode.check(text) else {
            error = "Check the 12-digit code shown on the host Mac."; return
        }
        guard let endpoint = pendingEndpoint, let identity else { return }
        error = nil
        dial(endpoint: endpoint, alpn: RemoteTLS.pairingALPN, pin: pendingPin) { [weak self] c, fingerprint in
            DispatchQueue.global(qos: .userInitiated).async {
                let key = PairingProof.codeKey(code: code, macFingerprint: fingerprint)
                DispatchQueue.main.async {
                    guard let self, self.connection === c, let key else { return }
                    let proof = PairingProof.deviceProof(key: key, deviceFingerprint: identity.fingerprint, macFingerprint: fingerprint)
                    self.send(.pairRequest, Wire.encode(PairRequest(method: PairRequest.code, proof: Base64URL.encode(proof),
                              name: Host.current().localizedName ?? "Mac", model: "Sill Viewer")))
                    self.read(c) { [weak self] header, data in
                        guard let self else { return }
                        guard header.kind == .pairResult, let result = Wire.decode(PairResult.self, from: data) else {
                            self.fail("Invalid pairing response."); return
                        }
                        guard ViewerTrust.accepts(result, key: key, host: fingerprint, device: identity.fingerprint),
                              let recognition = result.recognitionKey.flatMap(Base64URL.decode) else {
                            self.closeConnection()
                            self.busy = false
                            self.status = "Enter the code shown on \(self.pairingName)."
                            self.error = result.ok ? "The host could not prove its identity." : "Pairing refused (\(result.reason ?? "unknown")). Check the code or show a fresh code on the host and try again."
                            return
                        }
                        let host = ViewerHost(name: result.name ?? self.pairingName, fingerprint: fingerprint,
                                              recognitionKey: recognition, serviceName: self.pendingService, address: self.pendingAddress)
                        var saved = self.saved.filter { $0.id != host.id }
                        saved.append(host)
                        do { try ViewerStore.save(saved) }
                        catch { self.fail(error.localizedDescription); return }
                        self.saved = saved
                        self.pairing = false
                        self.session(endpoint: endpoint, pin: fingerprint)
                    }
                }
            }
        }
    }

    private func session(endpoint: NWEndpoint, pin: Data) {
        closeConnection()
        receivedCatalog = false
        dial(endpoint: endpoint, alpn: RemoteTLS.sessionALPN, pin: pin) { [weak self] c, _ in
            guard let self else { return }
            self.send(.hello, Wire.encode(Hello(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
                                               build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev",
                                               protocol: SillProtocol.current,
                                               device: Host.current().localizedName ?? "Sill Viewer")))
            self.sendViewport()
            self.read(c) { [weak self] header, data in self?.received(header, data) }
        }
    }

    private func dial(endpoint: NWEndpoint, alpn: String, pin: Data?, ready: @escaping (NWConnection, Data) -> Void) {
        closeConnection()
        guard let identity else { fail("Viewer identity is unavailable. Restart after unlocking Keychain."); return }
        busy = true
        status = "Connecting to \(pairingName)…"
        let tls = RemoteTLS.options(identity: identity.tls, role: .client(alpn: alpn), verify: { fingerprint in
            guard let fingerprint else { return false }
            return pin == nil || pin == fingerprint
        }, queue: .main)
        let c = NWConnection(to: endpoint, using: RemoteTLS.parameters(tls: tls, dialing: true))
        connection = c
        let timeout = DispatchWorkItem { [weak self, weak c] in
            guard let self, let c, self.connection === c else { return }
            self.fail("Connection timed out. Check the host, address and pairing. A changed host key requires removing the saved Mac and pairing again.")
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, self.connection === c else { return }
            switch state {
            case .ready:
                guard let fingerprint = RemoteTLS.peerFingerprint(c), RemoteTLS.negotiatedALPN(c) == alpn else {
                    self.fail("The host did not negotiate the Sill secure protocol."); return
                }
                ready(c, fingerprint)
            case .failed(let error): self.fail("Connection failed: \(error.localizedDescription)")
            default: break
            }
        }
        c.start(queue: .main)
    }

    private func read(_ c: NWConnection, message: @escaping (StreamHeader, Data) -> Void) {
        reader = MessageReader(connection: c, stillReads: { [weak self, weak c] in
            guard let c else { return false }; return self?.connection === c
        }, onBytes: { [weak self] _ in self?.lastFrameAt = Date() }, onMessage: message, onEnd: { [weak self] end in
            if case .tooBig = end { self?.fail("The host sent an oversized message.") }
            else { self?.fail("The connection ended. Reconnect when the host is available.") }
        })
        reader?.start()
    }

    private func received(_ header: StreamHeader, _ data: Data) {
        switch header.kind {
        case .windowList:
            guard let list = Wire.decode(WindowList.self, from: data) else { fail("Invalid window list."); return }
            windows = list.windows
            source = list.active
            status = "Connected to \(list.macName)"
            if !receivedCatalog {
                receivedCatalog = true
                deadline?.cancel()
                busy = false
                connected = true
                awaitPicture()
                lastFrameAt = Date()
                heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if Date().timeIntervalSince(self.lastFrameAt) > 20 { self.fail("The host stopped responding."); return }
                    self.send(.ping, Data(repeating: 0, count: 8))
                }
                if list.active == .none { select(.desktop) }
                onConnected?()
            }
        case .parameterSets:
            guard let sets = ParameterSets(encoded: data), sets.sets.count == 3,
                  [1, 2, 4].contains(sets.nalUnitHeaderLength), sets.sets.allSatisfy({ !$0.isEmpty }) else {
                fail("Invalid HEVC parameters."); return
            }
            onParameters?(sets)
        case .frame: onFrame?(data, header.isKeyframe)
        case .cursorShape:
            if let cursor = CursorShapeBlob.decode(data), cursor.size.width.isFinite, cursor.size.height.isFinite,
               cursor.size.width > 0, cursor.size.height > 0, cursor.size.width <= 512, cursor.size.height <= 512,
               cursor.hotspot.x.isFinite, cursor.hotspot.y.isFinite, let image = NSImage(data: cursor.png) {
                image.size = cursor.size
                onCursor?(NSCursor(image: image, hotSpot: cursor.hotspot))
            }
        case .goodbye:
            let goodbye = Wire.decode(Goodbye.self, from: data)
            fail(goodbye?.message ?? "The host closed this session.")
        default: break
        }
    }

    func select(_ value: StreamSource) {
        onClear?()
        awaitPicture()
        source = value
        send(.selectSource, Wire.encode(value))
    }

    func viewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard size != lastViewport else { return }
        lastViewport = size
        if connected { sendViewport() }
    }

    private func sendViewport() {
        send(.viewport, Wire.encode(Viewport(width: lastViewport.width, height: lastViewport.height, scale: nil, localCursor: true, fps: 60)))
    }

    func awaitPicture() {
        pictureReady = false
        pictureDeadline?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connected, !self.pictureReady else { return }
            self.error = "Connected, but no picture arrived. Check Screen Recording permission for Sill on the host Mac, keep it awake, then choose Desktop or a window again."
            self.requestKeyframe()
        }
        pictureDeadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func receivedPicture(size: CGSize) {
        guard !pictureReady else { return }
        pictureReady = true
        pictureDeadline?.cancel()
        logger.info("Picture received: \(Int(size.width))×\(Int(size.height))")
    }

    func input(_ value: InputEvent) { if connected { send(.input, Wire.encode(value)) } }
    func requestKeyframe() { if connected { send(.keyframeRequest, Data()) } }

    private func send(_ kind: StreamMessageKind, _ data: Data) {
        guard let c = connection else { return }
        c.send(content: StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970, isKeyframe: false, payload: data).serialized(),
               completion: .contentProcessed { [weak self, weak c] error in
            guard let self, let c, self.connection === c else { return }
            if let error { self.fail(error.localizedDescription) }
        })
    }

    func forget(_ host: ViewerHost) {
        let remaining = saved.filter { $0.id != host.id }
        do { try ViewerStore.save(remaining); saved = remaining }
        catch { self.error = error.localizedDescription }
    }

    func disconnect() {
        onClear?()
        closeConnection(graceful: connected)
        connected = false
        pictureReady = false
        busy = false
        pairing = false
        windows = []
        source = .none
        status = "Looking for Macs…"
    }

    private func closeConnection(graceful: Bool = false) {
        pictureDeadline?.cancel()
        pictureDeadline = nil
        heartbeat?.invalidate()
        heartbeat = nil
        deadline?.cancel()
        deadline = nil
        let c = connection
        connection = nil
        c?.stateUpdateHandler = nil
        if graceful, let c {
            // Queue the FIN after releaseInput's key/button ups, then close after they drain.
            c.send(content: nil, contentContext: .finalMessage, isComplete: true,
                   completion: .contentProcessed { _ in c.cancel() })
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { c.cancel() }
        } else { c?.cancel() }
        reader = nil
    }

    private func fail(_ message: String) {
        disconnect()
        error = message
    }
}
