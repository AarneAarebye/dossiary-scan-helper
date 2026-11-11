import Foundation

/// Looks up the text the menu and panels show. Keys are the English text; `lookup` returns the
/// translation (the key itself when there is none), and arguments are filled in with String(format:).
/// Only what a person sees goes through here: messages sent to Dossiary in protocol answers stay English.
public struct Texts: Sendable {
    public let lookup: @Sendable (String) -> String

    public init(lookup: @escaping @Sendable (String) -> String) { self.lookup = lookup }

    /// The keys themselves, for tests and anything without an app bundle.
    public static let english = Texts { $0 }
    /// The app bundle's <lang>.lproj/Localizable.strings, in the person's preferred language.
    public static let bundle = Texts { Bundle.main.localizedString(forKey: $0, value: $0, table: nil) }

    public func callAsFunction(_ key: String, _ args: CVarArg...) -> String {
        let template = lookup(key)
        return args.isEmpty ? template : String(format: template, arguments: args)
    }

    /// An error as a panel shows it. The helper's own errors are translated here (their errorDescription
    /// stays English, since it also reaches Dossiary); a scan server's refusal and system errors are shown
    /// as they come.
    public func errorText(_ error: Error) -> String {
        let t = self
        switch error {
        case PairingFailure.notAScanServer: return t("That address isn't a scanix500 network scan server.")
        case PairingFailure.timedOut: return t("The Scan button wasn't pressed within 2 minutes. Try again.")
        case PairingFailure.conflict: return t("Another computer tried to pair at the same time. Try again with only one computer.")
        case PairingFailure.tooMany: return t("Too many pairing requests. Wait a minute, then try again.")
        case PairingFailure.refused(let message): return message
        case RemoteError.unreachable(let detail): return t("The network scanner can't be reached (%@).", detail)
        case RemoteError.certificateChanged(let seen):
            return t("The network scanner presented a different certificate (%@) from the one used during pairing. If the server was reinstalled, remove the scanner from Dossiary Scan Helper and add it again.",
                     RemoteFingerprint.display(seen))
        default: return error.localizedDescription
        }
    }

    /// The menu line for a problem the button scan pickup reports.
    public func buttonScanProblem(_ problem: ButtonScanProblem) -> String {
        let t = self
        switch problem {
        case .cannotSave(let reason): return t("Button scans can't be saved: %@", reason)
        case .cannotRecord(let reason): return t("Picked-up scans can't be recorded: %@", reason)
        case .tooLarge(let server): return t("%@ has a button scan that is too large to pick up.", server)
        }
    }

    /// The notification for a finished profile scan. File names and the scanner's own messages are shown as they come.
    public func profileScanSummary(_ outcome: ProfileScanOutcome) -> (title: String, body: String) {
        let t = self
        func names(_ files: [URL]) -> String { files.map(\.lastPathComponent).joined(separator: ", ") }
        switch outcome {
        case .saved(let files, let pages, let searchable):
            let title = pages == 1 ? t("1 page scanned") : t("%lld pages scanned", pages)
            let note = searchable == false ? " — " + t("The scan was saved without searchable text; text recognition didn't finish.") : ""
            return (title, names(files) + note)
        case .partial(let files, let message):
            return (t("Scan incomplete"), names(files) + " — " + message)
        case .failed(let message):
            return (t("Scan failed"), message)
        }
    }
}
