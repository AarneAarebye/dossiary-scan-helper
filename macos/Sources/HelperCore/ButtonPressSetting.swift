import Foundation

/// Whether the helper makes a sound when a button is pressed on a paired scan server. Remembered in UserDefaults; on by default.
public final class ButtonPressSetting: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "buttonPressSound") {
        self.defaults = defaults; self.key = key
    }

    public var isOn: Bool { defaults.object(forKey: key) as? Bool ?? true }

    public func set(_ on: Bool) { defaults.set(on, forKey: key) }
}
