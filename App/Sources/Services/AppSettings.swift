import Foundation
import Observation

/// App-wide preferences. Stored properties keep @Observable simple; explicit
/// setters persist to UserDefaults.
@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private(set) var keyNotation: KeyNotationStyle
    private(set) var snapEnabled: Bool
    private(set) var snapToBeats: Bool
    private(set) var followPlayhead: Bool
    private(set) var defaultCrossfade: Double

    private init() {
        let defaults = UserDefaults.standard
        keyNotation = KeyNotationStyle(rawValue: defaults.string(forKey: "keyNotation") ?? "") ?? .camelot
        snapEnabled = defaults.object(forKey: "snapEnabled") as? Bool ?? true
        snapToBeats = defaults.object(forKey: "snapToBeats") as? Bool ?? true
        followPlayhead = defaults.object(forKey: "followPlayhead") as? Bool ?? true
        defaultCrossfade = defaults.object(forKey: "defaultCrossfade") as? Double ?? 8.0
    }

    func setKeyNotation(_ value: KeyNotationStyle) {
        keyNotation = value
        UserDefaults.standard.set(value.rawValue, forKey: "keyNotation")
    }

    func setSnapEnabled(_ value: Bool) {
        snapEnabled = value
        UserDefaults.standard.set(value, forKey: "snapEnabled")
    }

    func setSnapToBeats(_ value: Bool) {
        snapToBeats = value
        UserDefaults.standard.set(value, forKey: "snapToBeats")
    }

    func setFollowPlayhead(_ value: Bool) {
        followPlayhead = value
        UserDefaults.standard.set(value, forKey: "followPlayhead")
    }

    func setDefaultCrossfade(_ value: Double) {
        defaultCrossfade = value
        UserDefaults.standard.set(value, forKey: "defaultCrossfade")
    }
}
