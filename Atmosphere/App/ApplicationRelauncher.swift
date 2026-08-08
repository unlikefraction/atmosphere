import AppKit
import Foundation

@MainActor
enum ApplicationRelauncher {
    /// Starts a tiny detached helper that waits for this process to finish its
    /// normal shutdown, then opens the same app bundle as a fresh process.
    @discardableResult
    static func relaunch() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundleURL.path
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\"",
            "atmosphere-relauncher",
            String(currentPID),
            bundlePath
        ]

        do {
            try helper.run()
        } catch {
            return false
        }

        NSApp.terminate(nil)
        return true
    }
}
