import AppKit
import HelperCore

/// The sound for a button press on a paired scan server: Pop for a scan button, Hero for finish.
/// Played on the main thread, from a copy, so a quick second press is not dropped.
enum ButtonPressSound {
    static func play(_ press: ButtonPress) {
        let name = press == .finish ? "Hero" : "Pop"
        DispatchQueue.main.async {
            (NSSound(named: name)?.copy() as? NSSound)?.play()
        }
    }
}
