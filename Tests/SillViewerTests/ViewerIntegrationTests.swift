import AppKit
import AVFoundation
import Combine
import XCTest
import StreamProtocol
@testable import SillViewer

final class ViewerIntegrationTests: XCTestCase {
    @MainActor
    func testPairStreamAndReconnectToSyntheticHost() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["SILL_VIEWER_TEST_ADDRESS"], let code = env["SILL_VIEWER_TEST_CODE"] else {
            throw XCTSkip("Run Scripts/test-viewer-stream.py for the encrypted synthetic-host integration test.")
        }
        _ = NSApplication.shared
        let client = ViewerClient()
        let initialIDs = Set(client.saved.map(\.id))
        let surface = ViewerSurface(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        surface.bind(client)
        let window = NSWindow(contentRect: surface.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.orderFront(nil)
        defer {
            client.disconnect()
            window.orderOut(nil)
            for host in client.saved where !initialIDs.contains(host.id) { client.forget(host) }
        }
        let paired = expectation(description: "Code pairing and verified session")
        let picture = expectation(description: "HEVC frames rendered")
        var subscriptions = Set<AnyCancellable>()
        client.$status.sink { print("viewer status: \($0)") }.store(in: &subscriptions)
        client.$error.sink { print("viewer error: \($0 ?? "none")") }.store(in: &subscriptions)
        var sentCode = false
        var connected = false
        var rendered = false
        client.$pairing.sink { value in
            if value && !sentCode {
                sentCode = true
                DispatchQueue.main.async { client.pair(code: code) }
            }
        }.store(in: &subscriptions)
        client.$connected.sink { value in
            if value && !connected { connected = true; paired.fulfill() }
        }.store(in: &subscriptions)
        surface.onDecodedFrame = {
            guard !rendered, surface.decodedFrames >= 12,
                  let layer = surface.layer as? AVSampleBufferDisplayLayer,
                  layer.status == .rendering else { return }
            rendered = true
            picture.fulfill()
        }
        client.connectAddress(address)
        await fulfillment(of: [paired, picture], timeout: 35)
        XCTAssertTrue(client.connected, client.error ?? client.status)
        XCTAssertTrue(rendered)
        XCTAssertEqual(client.source, .desktop)
        guard let host = client.saved.first(where: { !initialIDs.contains($0.id) }) else {
            XCTFail("Verified host pin was not saved"); return
        }
        subscriptions.removeAll()
        var clearedWhileConnected = false
        let clearSurface = client.onClear
        client.onClear = { clearedWhileConnected = client.connected; clearSurface?() }
        client.disconnect()
        XCTAssertTrue(clearedWhileConnected, "Release input before closing the session")
        let reconnect = expectation(description: "Reconnect using the saved host key without another code")
        client.$connected.filter { $0 }.prefix(1).sink { _ in reconnect.fulfill() }.store(in: &subscriptions)
        client.connect(host)
        await fulfillment(of: [reconnect], timeout: 20)
        XCTAssertFalse(client.pairing)
        XCTAssertNil(client.error)
    }
}
