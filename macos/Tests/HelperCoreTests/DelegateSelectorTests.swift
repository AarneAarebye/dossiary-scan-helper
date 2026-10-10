import Foundation
import Testing
@testable import HelperCore

/// ImageCaptureCore's delegate methods are optional, so a misspelt one compiles and is simply never called.
@Test func backendImplementsTheDelegateCallbacksItReliesOn() {
    for name in ["deviceBrowser:didAddDevice:moreComing:", "deviceBrowser:didRemoveDevice:moreGoing:",
                 "didRemoveDevice:", "scannerDevice:didSelectFunctionalUnit:error:",
                 "scannerDevice:didScanToURL:", "scannerDevice:didCompleteScanWithError:"] {
        #expect(ImageCaptureBackend.instancesRespond(to: NSSelectorFromString(name)), "\(name)")
    }
}
