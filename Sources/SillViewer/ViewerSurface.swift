import AppKit
import AVFoundation
import StreamProtocol

final class ViewerSurface: NSView, NSTextInputClient {
    private let videoLayer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var lastParameters: Data?
    private var waitingForKeyframe = true
    private var videoSize = CGSize.zero
    private var cursor = NSCursor.arrow
    private var marked = NSAttributedString(string: "")
    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<Int>()
    private var lastPointer = CGPoint(x: 0.5, y: 0.5)
    private var scrollActive = false
    private var keyframeRequestedAt = Date.distantPast
    private weak var client: ViewerClient?
    var decodedFrames = 0
    var onDecodedFrame: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // AppKit keeps the backing layer in sync with view size and Retina scale changes.
    override func makeBackingLayer() -> CALayer { videoLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        setAccessibilityLabel("Remote Mac screen")
        setAccessibilityRole(.group)
        NotificationCenter.default.addObserver(self, selector: #selector(releaseInput), name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recoverPicture), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recoverPicture), name: .AVSampleBufferDisplayLayerFailedToDecode, object: videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func bind(_ client: ViewerClient) {
        self.client = client
        client.onParameters = { [weak self] in self?.apply($0) }
        client.onFrame = { [weak self] in self?.enqueue($0, keyframe: $1) }
        client.onClear = { [weak self] in self?.clear() }
        client.onCursor = { [weak self] cursor in
            guard let self else { return }
            self.cursor = cursor
            self.window?.invalidateCursorRects(for: self)
        }
    }

    override func layout() {
        super.layout()
        client?.viewport(bounds.size)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(ViewerInput.videoRect(bounds: bounds, video: videoSize), cursor: cursor)
    }

    func clear() {
        releaseInput()
        format = nil
        lastParameters = nil
        waitingForKeyframe = true
        videoSize = .zero
        marked = NSAttributedString(string: "")
        inputContext?.discardMarkedText()
        videoLayer.flushAndRemoveImage()
        window?.invalidateCursorRects(for: self)
    }

    private func apply(_ ps: ParameterSets) {
        guard ps.encoded() != lastParameters else { return }
        let buffers = ps.sets.map { bytes -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            bytes.copyBytes(to: p, count: bytes.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: buffers.count, parameterSetPointers: buffers.map { UnsafePointer($0) },
            parameterSetSizes: ps.sets.map(\.count), nalUnitHeaderLength: Int32(ps.nalUnitHeaderLength),
            extensions: nil, formatDescriptionOut: &desc)
        guard status == noErr, let desc else { client?.error = "Cannot decode HEVC format (\(status))."; return }
        client?.awaitPicture()
        lastParameters = ps.encoded()
        format = desc
        let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
        videoSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        waitingForKeyframe = true
        videoLayer.flushAndRemoveImage()
        window?.invalidateCursorRects(for: self)
    }

    private func enqueue(_ data: Data, keyframe: Bool) {
        guard let format, !data.isEmpty else { return }
        if videoLayer.status == .failed || videoLayer.requiresFlushToResumeDecoding {
            videoLayer.flush()
            waitingForKeyframe = true
        }
        if waitingForKeyframe && !keyframe { recoverPicture(); return }
        // Dropping an inter-frame also invalidates later dependent frames. Resume at a fresh keyframe.
        guard videoLayer.isReadyForMoreMediaData else { waitingForKeyframe = true; recoverPicture(); return }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
              blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count,
              flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        let status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var count = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
              sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
              sampleSizeArray: &count, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as NSArray?,
           let first = attachments.firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately as String] = true
        }
        waitingForKeyframe = false
        videoLayer.enqueue(sample)
        client?.receivedPicture(size: videoSize)
        decodedFrames += 1
        onDecodedFrame?()
    }

    @objc private func recoverPicture() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.recoverPicture() }; return
        }
        waitingForKeyframe = true
        if Date().timeIntervalSince(keyframeRequestedAt) >= 2 {
            keyframeRequestedAt = Date()
            client?.requestKeyframe()
        }
    }

    private func position(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        ViewerInput.position(convert(event.locationInWindow, from: nil), bounds: bounds, video: videoSize, clamp: clamp)
    }

    private func pointer(_ event: NSEvent, action: PointerAction, clamp: Bool = false) {
        guard let p = position(event, clamp: clamp) else { return }
        lastPointer = p
        client?.input(.pointer(action, x: p.x, y: p.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard position(event) != nil else { return }
        heldButtons.insert(0)
        pointer(event, action: .leftDown)
    }
    override func mouseUp(with event: NSEvent) {
        guard heldButtons.remove(0) != nil else { return }
        pointer(event, action: .leftUp, clamp: true)
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard position(event) != nil else { return }
        heldButtons.insert(1)
        pointer(event, action: .rightDown)
    }
    override func rightMouseUp(with event: NSEvent) {
        guard heldButtons.remove(1) != nil else { return }
        pointer(event, action: .rightUp, clamp: true)
    }
    override func mouseMoved(with event: NSEvent) { pointer(event, action: .move) }
    override func mouseDragged(with event: NSEvent) { pointer(event, action: .move, clamp: true) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, action: .move, clamp: true) }
    override func scrollWheel(with event: NSEvent) {
        guard let p = position(event, clamp: scrollActive) else { return }
        let rect = ViewerInput.videoRect(bounds: bounds, video: videoSize)
        lastPointer = p
        if event.phase.contains(.began) {
            scrollActive = true
            client?.input(.scrollGesture(.began, x: p.x, y: p.y))
        }
        if event.momentumPhase.contains(.began) {
            scrollActive = true
            client?.input(.scrollGesture(.momentumBegan, x: p.x, y: p.y))
        }
        let factor: Double = event.hasPreciseScrollingDeltas ? 1 : 10
        client?.input(.scroll(x: p.x, y: p.y, dx: event.scrollingDeltaX * factor / rect.width,
                             dy: event.scrollingDeltaY * factor / rect.height))
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scrollActive = false
            client?.input(.scrollGesture(.ended, x: p.x, y: p.y))
        }
        if event.momentumPhase.contains(.ended) {
            scrollActive = false
            client?.input(.scrollGesture(.momentumEnded, x: p.x, y: p.y))
        }
    }

    // Forward shortcuts while this view owns focus; keep app menus working elsewhere.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), let usage = ViewerInput.hidUsage(for: event.keyCode),
           event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) ||
           [36, 48, 51, 53, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(event.keyCode) || (0x3A...0x45).contains(usage) {
            heldKeys.insert(usage)
            client?.input(.key(hidUsage: usage, down: true, modifiers: UInt64(event.modifierFlags.rawValue)))
        } else { interpretKeyEvents([event]) }
    }
    override func flagsChanged(with event: NSEvent) {
        guard let change = ViewerInput.modifierChange(keyCode: event.keyCode,
                  flags: UInt64(event.modifierFlags.rawValue), held: heldKeys) else { return }
        if change.down { heldKeys.insert(change.usage) }
        else { heldKeys.remove(change.usage) }
        client?.input(.key(hidUsage: change.usage, down: change.down, modifiers: UInt64(event.modifierFlags.rawValue)))
    }

    override func keyUp(with event: NSEvent) {
        guard let usage = ViewerInput.hidUsage(for: event.keyCode), heldKeys.remove(usage) != nil else { return }
        client?.input(.key(hidUsage: usage, down: false, modifiers: UInt64(event.modifierFlags.rawValue)))
    }

    @objc func releaseInput() {
        for usage in heldKeys { client?.input(.key(hidUsage: usage, down: false, modifiers: 0)) }
        heldKeys.removeAll()
        for button in heldButtons {
            client?.input(.pointer(button == 0 ? .leftUp : .rightUp, x: lastPointer.x, y: lastPointer.y))
        }
        heldButtons.removeAll()
        if scrollActive { client?.input(.scrollGesture(.ended, x: lastPointer.x, y: lastPointer.y)); scrollActive = false }
    }
    override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }

    // Compose locally (including Korean IME); only committed Unicode is sent to the remote Mac.
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        marked = NSAttributedString(string: "")
        if !text.isEmpty {
            client?.input(.text(text))
            // The host clears modifiers for Unicode typing; restore those still held for clicks.
            for usage in heldKeys where (0xE0...0xE7).contains(usage) {
                client?.input(.key(hidUsage: usage, down: true, modifiers: UInt64(NSEvent.modifierFlags.rawValue)))
            }
        }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
    }
    func unmarkText() { marked = NSAttributedString(string: "") }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= marked.length else { return nil }
        actualRange?.pointee = range
        return marked.attributedSubstring(from: range)
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = selectedRange()
        let point = CGPoint(x: lastPointer.x * bounds.width, y: lastPointer.y * bounds.height)
        return window?.convertToScreen(convert(CGRect(origin: point, size: CGSize(width: 1, height: 20)), to: nil)) ?? .zero
    }
    override func doCommand(by selector: Selector) {
        let text: String?
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): text = "\n"
        case #selector(NSResponder.insertTab(_:)): text = "\t"
        case #selector(NSResponder.deleteBackward(_:)): text = "\u{8}"
        default: text = nil
        }
        if let text { client?.input(.text(text)) }
    }
}
