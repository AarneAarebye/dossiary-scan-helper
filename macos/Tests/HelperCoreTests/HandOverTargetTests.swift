import Foundation
import Testing
@testable import HelperCore

private let running = URL(fileURLWithPath: "/Applications/Running.app")
private let installed = URL(fileURLWithPath: "/Applications/Dossiary/Dossiary.app")
private let services = URL(fileURLWithPath: "/Users/x/build/Dossiary.app")

@Test func handOverTargetOrderIsRespectedWhenAllAreSet() {
    #expect(HandOverTarget.choose(running: running, installedInApplications: installed, launchServices: services) == running)
}

@Test func handOverTargetInstalledWinsWithoutARunningApp() {
    #expect(HandOverTarget.choose(running: nil, installedInApplications: installed, launchServices: services) == installed)
}

@Test func handOverTargetLaunchServicesIsTheLastResort() {
    #expect(HandOverTarget.choose(running: nil, installedInApplications: nil, launchServices: services) == services)
}

@Test func handOverTargetIsNilWhenNothingIsFound() {
    #expect(HandOverTarget.choose(running: nil, installedInApplications: nil, launchServices: nil) == nil)
}
