import XCTest
import CryptoKit
import StreamProtocol
@testable import SillViewer

final class ViewerTests: XCTestCase {
    func testPointerUsesVideoRectangle() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let video = CGSize(width: 1920, height: 1080)
        XCTAssertNil(ViewerInput.position(CGPoint(x: 500, y: 50), bounds: bounds, video: video))
        XCTAssertEqual(ViewerInput.position(CGPoint(x: 500, y: 400), bounds: bounds, video: video), CGPoint(x: 0.5, y: 0.5))
        let edge = ViewerInput.position(CGPoint(x: 1000, y: 800), bounds: bounds, video: video, clamp: true)!
        XCTAssertEqual(edge.x, 1, accuracy: 0.000001)
        XCTAssertEqual(edge.y, 1, accuracy: 0.000001)
        XCTAssertNil(ViewerInput.position(.zero, bounds: bounds, video: .zero))
    }

    func testZoomKeepsPointerOnSameRemotePoint() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let video = CGSize(width: 1000, height: 800)
        var zoom = ViewerZoom()
        let point = CGPoint(x: 750, y: 400)
        zoom.magnify(by: 2, around: point, bounds: bounds, video: video)
        let rect = zoom.videoRect(bounds: bounds, video: video)
        XCTAssertEqual((point.x - rect.minX) / rect.width, 0.75, accuracy: 0.000001)
        XCTAssertEqual(ViewerInput.position(point, in: rect)?.x ?? -1, 0.75, accuracy: 0.000001)
        XCTAssertEqual(ViewerInput.position(point, in: rect)?.y ?? -1, 0.5, accuracy: 0.000001)
        zoom.magnify(by: 0.01, around: point, bounds: bounds, video: video)
        XCTAssertEqual(zoom.videoRect(bounds: bounds, video: video), bounds)
    }

    func testZoomPanStopsAtPictureEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var zoom = ViewerZoom()
        zoom.magnify(by: 2, around: CGPoint(x: 500, y: 400), bounds: bounds, video: bounds.size)
        zoom.pan(by: CGSize(width: 10000, height: -10000), bounds: bounds, video: bounds.size)
        let rect = zoom.videoRect(bounds: bounds, video: bounds.size)
        XCTAssertEqual(rect.minX, bounds.minX)
        XCTAssertEqual(rect.maxY, bounds.maxY)
    }

    func testKeyboardUsesHIDCodesRatherThanMacKeyCodes() {
        XCTAssertEqual(ViewerInput.hidUsage(for: 0), 0x04) // A
        XCTAssertEqual(ViewerInput.hidUsage(for: 36), 0x28) // Return
        XCTAssertEqual(ViewerInput.hidUsage(for: 123), 0x50) // Left arrow
        XCTAssertNil(ViewerInput.hidUsage(for: 255))
    }

    func testModifierKeysKeepTheirOwnStateWhenBothShiftKeysAreHeld() {
        let shift = UInt64(1 << 17)
        XCTAssertEqual(ViewerInput.modifierChange(keyCode: 56, flags: shift, held: [])?.down, true)
        XCTAssertEqual(ViewerInput.modifierChange(keyCode: 56, flags: 0, held: [0xE1])?.down, false)
        XCTAssertEqual(ViewerInput.modifierChange(keyCode: 56, flags: shift, held: [0xE1, 0xE5])?.down, false)
        XCTAssertEqual(ViewerInput.modifierChange(keyCode: 60, flags: shift, held: [0xE1])?.usage, 0xE5)
        XCTAssertNil(ViewerInput.modifierChange(keyCode: 0, flags: shift, held: []))
    }

    func testPairingSavesOnlyTheHostThatProvedTheCode() {
        let host = Data(repeating: 1, count: 32)
        let device = Data(repeating: 2, count: 32)
        let key = SymmetricKey(data: Data(repeating: 3, count: 32))
        let proof = PairingProof.macProof(key: key, macFingerprint: host, deviceFingerprint: device)
        var result = PairResult(ok: true, proof: Base64URL.encode(proof), macID: MacID.make(fingerprint: host),
                                recognitionKey: Base64URL.encode(Data(repeating: 4, count: 32)))
        XCTAssertTrue(ViewerTrust.accepts(result, key: key, host: host, device: device))
        XCTAssertFalse(ViewerTrust.accepts(result, key: key, host: Data(repeating: 5, count: 32), device: device))
        result.macID = "another host"
        XCTAssertFalse(ViewerTrust.accepts(result, key: key, host: host, device: device))
        result.macID = MacID.make(fingerprint: host)
        result.proof = nil
        result.method = "cable"
        XCTAssertFalse(ViewerTrust.accepts(result, key: key, host: host, device: device))
    }
}
