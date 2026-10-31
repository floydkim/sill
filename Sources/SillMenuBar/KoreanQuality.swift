import StreamProtocol

extension QualityPreset {
    var koreanName: String {
        switch self {
        case .low: "낮음"
        case .efficient: "절약"
        case .balanced: "균형"
        case .high: "높음"
        case .pro: "전문가"
        case .ultra: "초고화질"
        case .extreme: "최고화질"
        }
    }

    var koreanTitle: String { "\(koreanName) — \(rawValue / 1_000_000) Mbps" }

    static func koreanName(forBitrate bitrate: Int) -> String {
        QualityPreset(rawValue: bitrate)?.koreanName ?? "\(mbps(bitrate)) Mbps"
    }

    static func koreanTitle(forBitrate bitrate: Int) -> String {
        QualityPreset(rawValue: bitrate)?.koreanTitle ?? "사용자 지정 — \(mbps(bitrate)) Mbps"
    }

    static func koreanShortTitle(bitrate: Int, captureScale: Double) -> String {
        "\(koreanName(forBitrate: bitrate)) · \(captureScale >= 1.5 ? "레티나" : "표준")"
    }

    static var koreanFastLinkNote: String {
        "초고화질과 최고화질은 USB 케이블이나 매우 빠른 Wi‑Fi가 필요합니다. 영상이 지연되면 품질을 낮춰 주세요."
    }
}
