import Foundation
import Testing
@testable import HelperCore

/// Marks every looked-up text, to prove a visible string went through Texts.
let marked = Texts { "‹" + $0 + "›" }

@Test func englishReturnsTheKeyAndFillsArguments() {
    #expect(Texts.english("Open log") == "Open log")
    #expect(Texts.english("Forget paired browsers (%lld)", 3) == "Forget paired browsers (3)")
    #expect(Texts.english("%1$@ at %2$@", "scanner", "10.0.0.5") == "scanner at 10.0.0.5")
}

@Test func lookupResultIsTheTemplate() {
    let german = Texts { $0 == "Remove “%@”" ? "„%@“ entfernen" : $0 }
    #expect(german("Remove “%@”", "attic") == "„attic“ entfernen")
}

@Test func errorTextInEnglishMatchesErrorDescription() {
    let errors: [Error] = [PairingFailure.notAScanServer, PairingFailure.timedOut, PairingFailure.conflict,
                           PairingFailure.tooMany, RemoteError.unreachable("timed out"),
                           RemoteError.certificateChanged(seen: String(repeating: "A", count: 64))]
    for error in errors {
        #expect(Texts.english.errorText(error) == (error as! LocalizedError).errorDescription)
    }
}

@Test func errorTextIsTranslated() {
    #expect(marked.errorText(PairingFailure.timedOut) == "‹The Scan button wasn't pressed within 2 minutes. Try again.›")
    #expect(marked.errorText(RemoteError.unreachable("timed out")) == "‹The network scanner can't be reached (timed out).›")
    // A refusal is the server's own message, shown as it came.
    #expect(marked.errorText(PairingFailure.refused("Wrong code.")) == "Wrong code.")
    // Anything else keeps its own (system) description.
    #expect(marked.errorText(URLError(.timedOut)) == URLError(.timedOut).localizedDescription)
}
