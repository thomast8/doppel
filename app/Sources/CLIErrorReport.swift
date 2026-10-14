import Foundation
import Darwin

enum CLIErrorReport {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Doppel/cli-errors.log")

    static func summary(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.contains(where: { $0.hasPrefix("ditto: ") && $0.hasSuffix(": No space left on device") }) {
            return "Your Mac ran out of disk space. Free up some space, then try again."
        }
        if let failure = lines.last(where: { $0.hasPrefix("doppel: ") }) {
            let message = String(failure.dropFirst("doppel: ".count))
            return message.count > 500 ? String(message.prefix(499)) + "…" : message
        }
        let message = lines.joined(separator: "\n")
        if !message.isEmpty, message.count <= 500, lines.count <= 3,
           !message.contains("% Total"), !message.contains("Dload  Upload") {
            return message
        }
        return "Doppel could not complete the operation. Check its local logs for details."
    }

    static func record(_ output: String, arguments: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        // Append without overwriting diagnostics from another failed command.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let entry = "\(Date().ISO8601Format()) doppel \(arguments.joined(separator: " "))\n\(output)\n\n"
        try handle.write(contentsOf: Data(entry.utf8))
    }
}
