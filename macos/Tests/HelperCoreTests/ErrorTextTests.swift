import Foundation
import Testing
@testable import HelperCore

/// The backend passes `error.localizedDescription` on to the person, so it must be our own text.
@Test func errorsDescribeThemselvesInPlainWords() {
    #expect(ProtocolError(503, "X was disconnected.").localizedDescription == "X was disconnected.")
    #expect(CallbackTimeout().localizedDescription == "The scanner didn't answer in time.")
}
