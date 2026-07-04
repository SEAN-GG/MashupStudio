import Foundation

enum TimeFormat {
    /// "mm:ss.cc" (centiseconds), used on the transport readout.
    static func position(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60
        let sec = Int(s) % 60
        let cs = Int((s - floor(s)) * 100)
        return String(format: "%02d:%02d.%02d", m, sec, cs)
    }

    /// "mm:ss" for durations and cards.
    static func short(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return String(format: "%02d:%02d", m, sec)
    }

    /// Parses "mm:ss", "mm:ss.cc" or "hh:mm:ss" into seconds.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":").map(String.init)
        guard parts.count >= 1, parts.count <= 3 else { return nil }
        var values: [Double] = []
        for p in parts {
            guard let v = Double(p.replacingOccurrences(of: ",", with: ".")), v >= 0 else { return nil }
            values.append(v)
        }
        var seconds = 0.0
        for v in values { seconds = seconds * 60 + v }
        return seconds
    }
}
