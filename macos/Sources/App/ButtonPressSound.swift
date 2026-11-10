import AppKit
import HelperCore

/// The sound for a button press on a paired scan server: Tink for a scan button, Glass for finish.
/// Played on the main thread, from a copy, so a quick second press is not dropped.
enum ButtonPressSound {
    static func play(_ press: ButtonPress) {
        let name = press == .finish ? "Glass" : "Tink"
        DispatchQueue.main.async {
            (NSSound(named: name)?.copy() as? NSSound)?.play()
        }
    }
}
