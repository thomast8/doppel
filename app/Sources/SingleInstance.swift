import Foundation

/// Ensures only one menu-bar instance runs at a time.
///
/// `open -a` will not start a second copy of a bundle, but launchd (and a
/// direct exec of the binary) bypasses that, which would put two identical
/// icons in the menu bar. An advisory lock held for the process lifetime is
/// authoritative regardless of how the process was started.
enum SingleInstance {
    private static var lockDescriptor: Int32 = -1

    /// Returns false when another instance already holds the lock.
    static func acquire(lockName: String = "menubar.lock") -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Doppel")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = directory.appendingPathComponent(lockName).path

        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return true }   // can't lock: don't block startup
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor                  // held until the process exits
        return true
    }
}
