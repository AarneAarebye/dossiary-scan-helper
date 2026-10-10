import Foundation
import Testing
@testable import HelperCore

@Test func callbackResumesOnce() async throws {
    let value: Int = try await awaitCallback(timeout: nil) { once in
        DispatchQueue.main.async {
            once.resume(.success(1))
            once.resume(.success(2))  // ignored
        }
    }
    #expect(value == 1)
}

@Test func callbackTimesOut() async {
    do {
        let _: Int = try await awaitCallback(timeout: 0.1) { _ in }
        Issue.record("expected a timeout")
    } catch {
        #expect(error is CallbackTimeout)
    }
}
