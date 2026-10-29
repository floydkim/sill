import Foundation
import CryptoKit
import StreamProtocol

enum ViewerInput {
    static func videoRect(bounds: CGRect, video: CGSize) -> CGRect {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func position(_ p: CGPoint, bounds: CGRect, video: CGSize, clamp: Bool = false) -> CGPoint? {
        let rect = videoRect(bounds: bounds, video: video)
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard clamp || rect.contains(p) else { return nil }
        return CGPoint(x: min(1, max(0, (p.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (p.y - rect.minY) / rect.height)))
    }

    static func modifierChange(keyCode: UInt16, flags: UInt64, held: Set<UInt16>) -> (usage: UInt16, down: Bool)? {
        guard let usage = hidUsage(for: keyCode) else { return nil }
        let masks: [UInt16: UInt64] = [0xE0: 1 << 18, 0xE4: 1 << 18,
                                      0xE1: 1 << 17, 0xE5: 1 << 17,
                                      0xE2: 1 << 19, 0xE6: 1 << 19,
                                      0xE3: 1 << 20, 0xE7: 1 << 20]
        guard let mask = masks[usage] else { return nil }
        // AppKit's flag combines both sides; the changed physical key toggles independently.
        return (usage, flags & mask != 0 && !held.contains(usage))
    }

    // Reverse of the host's HID-to-Mac mapping, so shortcuts use physical keys on every layout.
    static func hidUsage(for keyCode: UInt16) -> UInt16? { hidUsages[keyCode] }
    private static let hidUsages: [UInt16: UInt16] = [
        0: 0x04,
        11: 0x05,
        8: 0x06,
        2: 0x07,
        14: 0x08,
        3: 0x09,
        5: 0x0A,
        4: 0x0B,
        34: 0x0C,
        38: 0x0D,
        40: 0x0E,
        37: 0x0F,
        46: 0x10,
        45: 0x11,
        31: 0x12,
        35: 0x13,
        12: 0x14,
        15: 0x15,
        1: 0x16,
        17: 0x17,
        32: 0x18,
        9: 0x19,
        13: 0x1A,
        7: 0x1B,
        16: 0x1C,
        6: 0x1D,
        18: 0x1E,
        19: 0x1F,
        20: 0x20,
        21: 0x21,
        23: 0x22,
        22: 0x23,
        26: 0x24,
        28: 0x25,
        25: 0x26,
        29: 0x27,
        36: 0x28,
        53: 0x29,
        51: 0x2A,
        48: 0x2B,
        49: 0x2C,
        27: 0x2D,
        24: 0x2E,
        33: 0x2F,
        30: 0x30,
        42: 0x31,
        41: 0x33,
        39: 0x34,
        50: 0x35,
        43: 0x36,
        47: 0x37,
        44: 0x38,
        57: 0x39,
        122: 0x3A,
        120: 0x3B,
        99: 0x3C,
        118: 0x3D,
        96: 0x3E,
        97: 0x3F,
        98: 0x40,
        100: 0x41,
        101: 0x42,
        109: 0x43,
        103: 0x44,
        111: 0x45,
        115: 0x4A,
        116: 0x4B,
        117: 0x4C,
        119: 0x4D,
        121: 0x4E,
        124: 0x4F,
        123: 0x50,
        125: 0x51,
        126: 0x52,
        59: 0xE0,
        56: 0xE1,
        58: 0xE2,
        55: 0xE3,
        62: 0xE4,
        60: 0xE5,
        61: 0xE6,
        54: 0xE7
    ]
}

enum ViewerTrust {
    static func accepts(_ result: PairResult, key: SymmetricKey, host: Data, device: Data) -> Bool {
        guard result.ok, result.macID == MacID.make(fingerprint: host),
              let proof = result.proof.flatMap(Base64URL.decode),
              result.recognitionKey.flatMap(Base64URL.decode)?.count == 32 else { return false }
        return PairingProof.isValidMacProof(proof, key: key, macFingerprint: host, deviceFingerprint: device)
    }
}
