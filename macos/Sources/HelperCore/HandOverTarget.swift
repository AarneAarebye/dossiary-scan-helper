import Foundation

/// Which copy of Dossiary for Mac gets the scans. Several copies can be registered (build copies, a backup of an older version);
/// the app that is already running comes first, so no second instance starts on the same libraries.
public enum HandOverTarget {
    /// The first of: the running app, the copy in /Applications/Dossiary, whatever LaunchServices prefers.
    public static func choose(running: URL?, installedInApplications: URL?, launchServices: URL?) -> URL? {
        running ?? installedInApplications ?? launchServices
    }
}
