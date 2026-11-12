import AppKit
import AudioTapLib
import Foundation

/// Which processes a recording taps, split out of `DualSourceRecorder.swift`
/// to keep that file under the line cap. A clean seam: both functions are
/// static, touch no recorder state, and are tested on their own.
extension DualSourceRecorder {
    /// Resolve the PID set to tap for a meeting-matched root PID.
    ///
    /// Returns `[rootPID]` alone when the running-application bundle URL is
    /// unavailable (command-line tool, detached process) or enumeration
    /// finds no PIDs under it. Otherwise returns every PID under the bundle,
    /// prepending the root if enumeration somehow missed it — order matters
    /// for the aggregate device's cosmetic name tag (root first).
    static func resolveTapPIDs(rootPID: pid_t) -> [pid_t] {
        // A nested helper root (Firefox's GPU helper) moves up to its owning app first.
        let root = effectiveRootPID(
            rootPID: rootPID,
            responsibleFor: { ProcessResponsibility.responsiblePID(of: $0) },
            bundleURLOf: { NSRunningApplication(processIdentifier: $0)?.bundleURL },
            executablePath: ProcessTreeEnumerator.liveExecutablePath(for:),
        )
        return resolveTapPIDs(
            rootPID: root,
            bundleURL: NSRunningApplication(processIdentifier: root)?.bundleURL,
            enumerate: ProcessTreeEnumerator.pidsRooted(in:),
            // Safari's audio runs in WebKit XPC outside Safari.app — see ProcessResponsibility.tapPIDs.
            widen: { ProcessResponsibility.tapPIDs(rootPID: root, bundleDerived: $0) },
            select: ChromiumHelperFilter.audioRelevantPIDs,
        )
    }

    /// Moves a helper root up to the app that owns it.
    ///
    /// A browser's WebRTC power assertion can be held by a helper that lives in
    /// its own nested `.app` (Firefox's GPU helper). Enumerating that helper's
    /// bundle finds the helper alone, which has no audio object, so the tap
    /// throws "Failed to translate any of 1 PIDs". Promotes only when the
    /// responsible process's bundle contains the root's executable, so a
    /// process a shell launched (attributed to the terminal, which does not
    /// contain it) keeps its own root and the tap never widens onto the launcher.
    static func effectiveRootPID(
        rootPID: pid_t,
        responsibleFor: (pid_t) -> pid_t,
        bundleURLOf: (pid_t) -> URL?,
        executablePath: (pid_t) -> String?,
    ) -> pid_t {
        let owner = responsibleFor(rootPID)
        guard owner > 0, owner != rootPID,
              let ownerBundle = bundleURLOf(owner),
              let exe = executablePath(rootPID),
              exe.hasPrefix(ownerBundle.resolvingSymlinksInPath().path + "/")
        else { return rootPID }
        return owner
    }

    /// Test seam — same PID-set decision as `resolveTapPIDs(rootPID:)` but with
    /// the running-app bundle lookup, child-PID enumeration, the responsibility
    /// widening and the helper selection injected, so the empty-enumeration
    /// fallback, the already-includes-root passthrough, the load-bearing
    /// root-prepend ordering (aggregate device name tag; #84) and the
    /// widen-then-select order are unit-testable without real running processes.
    ///
    /// `select` runs last on purpose: `widen` attributes a Chromium helper to its
    /// browser just like the bundle walk does, so a helper dropped before the
    /// widening would be re-added by it (issue #791, `ChromiumHelperFilter`).
    static func resolveTapPIDs(
        rootPID: pid_t,
        bundleURL: URL?,
        enumerate: (URL) -> [pid_t],
        widen: ([pid_t]) -> [pid_t] = \.self,
        select: ([pid_t]) -> [pid_t] = \.self,
    ) -> [pid_t] {
        guard let bundleURL else { return [rootPID] }
        let enumerated = enumerate(bundleURL)
        // Empty `enumerated` needs no guard: it falls through to `[rootPID] + []`, the root alone.
        let bundleDerived = enumerated.contains(rootPID) ? enumerated : [rootPID] + enumerated
        return select(widen(bundleDerived))
    }
}
