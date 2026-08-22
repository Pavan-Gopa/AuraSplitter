import Foundation
import CryptoKit

/// Integrity + provenance checks applied to a downloaded update archive
/// BEFORE anything is swapped on disk.
enum UpdateVerifier {
    enum VerificationError: LocalizedError {
        case sha256Mismatch(expected: String, actual: String)
        case signatureInvalid(details: String)
        case teamIdentifierMismatch(expected: String, actual: String)
        case appNotFoundInArchive

        var errorDescription: String? {
            switch self {
            case .sha256Mismatch(let expected, let actual):
                return "Update archive failed the SHA-256 check (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
            case .signatureInvalid(let details):
                return "Downloaded update is not correctly signed: \(details)"
            case .teamIdentifierMismatch(let expected, let actual):
                return "Downloaded update was signed by '\(actual)' instead of '\(expected)'."
            case .appNotFoundInArchive:
                return "The update archive did not contain AuraSplitter.app."
            }
        }
    }
    /// Streaming SHA-256 of a file, lowercase hex.
    static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Expands the zip into a fresh temp directory and returns the .app URL.
    static func extractApp(from zipURL: URL, workDirectory: URL) throws -> URL {
        let extractDir = workDirectory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, extractDir.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            throw GitHubReleaseChecker.UpdateError.malformedPayload(
                "Unzip failed: " + (String(data: data, encoding: .utf8) ?? "unknown error")
            )
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil) else {
            throw VerificationError.appNotFoundInArchive
        }
        // The archive keeps the bundle at the root (--keepParent), but tolerate one level.
        for candidate in [extractDir.appendingPathComponent("AuraSplitter.app")] + contents where candidate.pathExtension == "app" {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        throw VerificationError.appNotFoundInArchive
    }

    /// Verifies code signature validity and, when the running bundle carries a
    /// real Team ID, that the update was signed by the same team.
    static func verifyCodeSignature(of newAppURL: URL, currentAppURL: URL?) throws {
        // 1. Structural validity.
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", newAppURL.path]
        let verifyErr = Pipe()
        verify.standardError = verifyErr
        try verify.run()
        verify.waitUntilExit()
        if verify.terminationStatus != 0 {
            let data = verifyErr.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "codesign exited \(verify.terminationStatus)"
            throw VerificationError.signatureInvalid(details: details)
        }

        // 2. Same-team check — only enforced when the running build has a Team ID
        //    (Developer ID / Apple Development). Ad-hoc dev builds skip this so
        //    local self-update keeps working.
        guard let currentTeam = teamIdentifier(of: currentAppURL), !currentTeam.isEmpty else { return }
        let newTeam = teamIdentifier(of: newAppURL) ?? ""
        if newTeam != currentTeam {
            throw VerificationError.teamIdentifierMismatch(expected: currentTeam, actual: newTeam.isEmpty ? "<none>" : newTeam)
        }
    }

    /// Parses `TeamIdentifier=` from `codesign -dv`.
    static func teamIdentifier(of appURL: URL?) -> String? {
        guard let appURL else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", appURL.path]
        let pipe = Pipe()
        process.standardError = pipe // codesign -d writes identity info to stderr
        process.standardOutput = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("TeamIdentifier=") {
                let value = trimmed.dropFirst("TeamIdentifier=".count)
                return value == "not set" ? nil : String(value)
            }
        }
        return nil
    }
}
