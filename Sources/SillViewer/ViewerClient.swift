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
    @Published var status = "Mac을 찾는 중…" {
        didSet { logger.info("\(self.status, privacy: .public)") }
    }
    @Published var connected = false
    @Published var pictureReady = false
    @Published var busy = false
    @Published var windows: [WindowInfo] = []
    @Published var source: StreamSource = .none
    @Published var thumbnails: [UInt32: NSImage] = [:]
    @Published var displays: [DisplayInfo] = []
    @Published var desktopDisplayID: UInt32?
    @Published var supportsSpaces = false
    @Published var hostSettings: HostSettingsState?
    @Published var settingsPending = false
    @Published var settingsNotice: String?
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
    private var settingsToken = 0
    private var pendingSettings: HostSettingsChange?
    private var settingsDeadline: DispatchWorkItem?
    private var displayFPS = 60
    private var pictureTimedOut = false
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
        error = "Mac을 찾을 수 없습니다 (\(errorDict)). 시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 Sill 뷰어를 허용한 뒤 새로 고침을 누르세요."
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
        guard host.encrypted else { fail("\(host.name)의 Sill을 업데이트하세요. 이 뷰어는 암호화된 연결을 지원하는 호스트가 필요합니다."); return }
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
        guard let endpoint = endpoint(text) else { fail("호스트 이름 또는 IP 주소를 입력하세요. 필요하면 뒤에 :포트를 붙일 수 있습니다 (기본 7455)."); return }
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
                    self.fail("잘못된 페어링 응답입니다."); return
                }
                self.closeConnection()
                self.pairing = true
                self.busy = false
                self.status = "\(self.pairingName)에 표시된 코드를 입력하세요."
                if result.reason != PairResult.shown {
                    self.error = "원격 Mac에서 Sill → iPhone 또는 iPad 페어링…을 열어 코드를 표시하세요."
                }
            }
        }
    }

    func pair(code text: String) {
        guard case .success(let code) = PairingCode.check(text) else {
            error = "원격 Mac에 표시된 12자리 코드를 확인하세요."; return
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
                            self.fail("잘못된 페어링 응답입니다."); return
                        }
                        guard ViewerTrust.accepts(result, key: key, host: fingerprint, device: identity.fingerprint),
                              let recognition = result.recognitionKey.flatMap(Base64URL.decode) else {
                            self.closeConnection()
                            self.busy = false
                            self.status = "\(self.pairingName)에 표시된 코드를 입력하세요."
                            self.error = result.ok ? "원격 Mac의 신원을 확인할 수 없습니다." : "페어링이 거부됐습니다 (\(result.reason ?? "알 수 없음")). 코드를 확인하거나 원격 Mac에서 새 코드를 표시한 뒤 다시 시도하세요."
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
        guard let identity else { fail("뷰어의 인증 정보를 사용할 수 없습니다. 키체인 잠금을 해제한 뒤 다시 실행하세요."); return }
        busy = true
        status = "\(pairingName)에 연결하는 중…"
        let tls = RemoteTLS.options(identity: identity.tls, role: .client(alpn: alpn), verify: { fingerprint in
            guard let fingerprint else { return false }
            return pin == nil || pin == fingerprint
        }, queue: .main)
        let c = NWConnection(to: endpoint, using: RemoteTLS.parameters(tls: tls, dialing: true))
        connection = c
        let timeout = DispatchWorkItem { [weak self, weak c] in
            guard let self, let c, self.connection === c else { return }
            self.fail("연결 시간이 초과됐습니다. 원격 Mac, 주소, 페어링 상태를 확인하세요. 원격 Mac의 키가 바뀌었다면 저장된 Mac을 삭제하고 다시 페어링해야 합니다.")
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, self.connection === c else { return }
            switch state {
            case .ready:
                guard let fingerprint = RemoteTLS.peerFingerprint(c), RemoteTLS.negotiatedALPN(c) == alpn else {
                    self.fail("원격 Mac과 Sill 보안 프로토콜을 협상하지 못했습니다."); return
                }
                ready(c, fingerprint)
            case .failed(let error): self.fail("연결 실패: \(error.localizedDescription)")
            default: break
            }
        }
        c.start(queue: .main)
    }

    private func read(_ c: NWConnection, message: @escaping (StreamHeader, Data) -> Void) {
        reader = MessageReader(connection: c, stillReads: { [weak self, weak c] in
            guard let c else { return false }; return self?.connection === c
        }, onBytes: { [weak self] _ in self?.lastFrameAt = Date() }, onMessage: message, onEnd: { [weak self] end in
            if case .tooBig = end { self?.fail("원격 Mac이 허용 크기를 넘는 메시지를 보냈습니다.") }
            else { self?.fail("연결이 종료됐습니다. 원격 Mac을 사용할 수 있을 때 다시 연결하세요.") }
        })
        reader?.start()
    }

    private func received(_ header: StreamHeader, _ data: Data) {
        switch header.kind {
        case .windowList:
            guard let list = Wire.decode(WindowList.self, from: data) else { fail("잘못된 앱 창 목록입니다."); return }
            windows = list.windows
            displays = list.displays ?? []
            desktopDisplayID = list.desktopDisplayID
            let windowIDs = Set(windows.map(\.id))
            thumbnails = thumbnails.filter { windowIDs.contains($0.key) }
            supportsSpaces = (list.gestures ?? 0) >= TrackpadGesture.generation
            if list.active != .none {
                source = list.active
            } else if pictureReady {
                onClear?()
                awaitPicture()
            }
            status = "\(list.macName)에 연결됨"
            if !receivedCatalog {
                receivedCatalog = true
                deadline?.cancel()
                busy = false
                connected = true
                awaitPicture()
                lastFrameAt = Date()
                heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if Date().timeIntervalSince(self.lastFrameAt) > 20 { self.fail("원격 Mac의 응답이 없습니다."); return }
                    self.send(.ping, Data(repeating: 0, count: 8))
                }
                if list.active == .none { select(.desktop) }
                onConnected?()
            }
        case .hostSettings:
            guard let state = Wire.decode(HostSettingsState.self, from: data) else { return }
            hostSettings = state
            if let change = pendingSettings, state.answering == change.token {
                settingsDeadline?.cancel()
                pendingSettings = nil
                settingsPending = false
                let accepted = change.applied(to: state.settings) == state.settings
                settingsNotice = accepted ? "원격 Mac에 적용됐습니다." : "원격 Mac이 설정을 적용하지 않았습니다. 현재 설정값을 표시합니다."
                logger.notice("Quality reply: accepted=\(accepted), bitrate=\(state.settings.bitrate), scale=\(state.settings.captureScale), fps=\(state.settings.maxFPS)")
            }
        case .parameterSets:
            guard let sets = ParameterSets(encoded: data), sets.sets.count == 3,
                  [1, 2, 4].contains(sets.nalUnitHeaderLength), sets.sets.allSatisfy({ !$0.isEmpty }) else {
                fail("잘못된 HEVC 매개변수입니다."); return
            }
            onParameters?(sets)
        case .frame: onFrame?(data, header.isKeyframe)
        case .thumbnail:
            if let thumbnail = ImageBlob.decodeThumbnail(data),
               windows.contains(where: { $0.id == thumbnail.windowID }),
               let image = NSImage(data: thumbnail.jpeg) {
                thumbnails[thumbnail.windowID] = image
            }
        case .cursorShape:
            if let cursor = CursorShapeBlob.decode(data), cursor.size.width.isFinite, cursor.size.height.isFinite,
               cursor.size.width > 0, cursor.size.height > 0, cursor.size.width <= 512, cursor.size.height <= 512,
               cursor.hotspot.x.isFinite, cursor.hotspot.y.isFinite, let image = NSImage(data: cursor.png) {
                image.size = cursor.size
                onCursor?(NSCursor(image: image, hotSpot: cursor.hotspot))
            }
        case .goodbye:
            let goodbye = Wire.decode(Goodbye.self, from: data)
            fail(goodbye?.message ?? "원격 Mac이 연결을 종료했습니다.")
        default: break
        }
    }

    func selectDisplay(_ id: UInt32) {
        guard connected, displays.contains(where: { $0.id == id }) else { return }
        onClear?()
        awaitPicture()
        source = .desktop
        desktopDisplayID = id
        send(.selectDisplay, Wire.encode(id))
    }

    func select(_ value: StreamSource) {
        if value == .desktop, let id = desktopDisplayID, displays.contains(where: { $0.id == id }) {
            selectDisplay(id)
            return
        }
        onClear?()
        awaitPicture()
        source = value
        send(.selectSource, Wire.encode(value))
    }

    func desktopGesture(_ gesture: String) {
        guard connected, supportsSpaces else { return }
        // The released host queues gestures behind a pending Desktop selection.
        if source != .desktop { select(.desktop) }
        send(.gesture, Wire.encode(TrackpadGesture(gesture: gesture)))
    }

    func changeSettings(_ requested: HostSettingsChange) {
        guard connected, hostSettings != nil, !settingsPending, !requested.isEmpty else { return }
        settingsToken += 1
        var change = requested
        change.token = settingsToken
        pendingSettings = change
        settingsPending = true
        settingsNotice = nil
        send(.changeSettings, Wire.encode(change))
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pendingSettings?.token == change.token else { return }
            self.pendingSettings = nil
            self.settingsPending = false
            self.settingsNotice = "원격 Mac의 확인 응답이 없습니다. 마지막으로 받은 설정을 표시합니다."
        }
        settingsDeadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    func viewport(_ size: CGSize, fps: Int = 60) {
        guard size.width > 0, size.height > 0 else { return }
        guard size != lastViewport || fps != displayFPS else { return }
        lastViewport = size
        displayFPS = fps
        if connected { sendViewport() }
    }

    private func sendViewport() {
        send(.viewport, Wire.encode(Viewport(width: lastViewport.width, height: lastViewport.height, scale: nil, localCursor: true, fps: displayFPS)))
    }

    func awaitPicture() {
        pictureReady = false
        pictureDeadline?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connected, !self.pictureReady else { return }
            self.pictureTimedOut = true
            self.error = "연결됐지만 영상을 받을 수 없습니다. 선택한 화면을 10초마다 다시 요청합니다. 원격 Mac이 잠겨 있다면 잠금을 해제하세요."
            var retry = self.source == .none ? StreamSource.desktop : self.source
            if case .window(let id) = retry, !self.windows.contains(where: { $0.id == id }) { retry = .desktop }
            self.logger.notice("Retrying screen selection for the released Sill host")
            self.select(retry)
        }
        pictureDeadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func receivedPicture(size: CGSize) {
        guard !pictureReady else { return }
        pictureReady = true
        pictureDeadline?.cancel()
        if pictureTimedOut { error = nil; pictureTimedOut = false }
        logger.info("Picture received: \(Int(size.width))×\(Int(size.height))")
    }

    func input(_ value: InputEvent) { if connected { send(.input, Wire.encode(value)) } }
    func requestKeyframe() {
        guard connected else { return }
        // v0.5.1 ignores kind 44; recover through selectSource after the picture timeout.
        if pictureReady {
            onClear?()
            awaitPicture()
        }
    }

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
        pictureTimedOut = false
        busy = false
        pairing = false
        windows = []
        thumbnails = [:]
        supportsSpaces = false
        displays = []
        desktopDisplayID = nil
        hostSettings = nil
        settingsDeadline?.cancel()
        settingsDeadline = nil
        pendingSettings = nil
        settingsPending = false
        settingsNotice = nil
        source = .none
        status = "Mac을 찾는 중…"
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
