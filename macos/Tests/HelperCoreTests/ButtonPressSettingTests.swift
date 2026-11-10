import Foundation
import Testing
@testable import HelperCore

@Test func buttonPressSettingDefaultsOnAndPersists() {
    let name = "ButtonPressSettingTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    #expect(ButtonPressSetting(defaults: defaults).isOn)
    ButtonPressSetting(defaults: defaults).set(false)
    #expect(!ButtonPressSetting(defaults: UserDefaults(suiteName: name)!).isOn)
    ButtonPressSetting(defaults: defaults).set(true)
    #expect(ButtonPressSetting(defaults: UserDefaults(suiteName: name)!).isOn)
}
