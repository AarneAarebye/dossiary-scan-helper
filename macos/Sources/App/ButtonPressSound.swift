import AppKit
import HelperCore

/// The sound for a button press on a paired scan server: Tink for a scan button, Glass for finish.
enum ButtonPressSound {
    static func play(_ press: ButtonPress) {
        NSSound(named: press == .finish ? "Glass" : "Tink")?.play()
    }
}
