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

    var koreanTitle: String { "\(koreanName) — \(Self.mbps(rawValue)) Mbps" }

    static func koreanTitle(forBitrate bitrate: Int) -> String {
        QualityPreset(rawValue: bitrate)?.koreanTitle ?? "사용자 설정 — \(mbps(bitrate)) Mbps"
    }
}
