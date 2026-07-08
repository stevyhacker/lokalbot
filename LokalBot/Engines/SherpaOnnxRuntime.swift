import Foundation

/// Shared sherpa-onnx runtime installer. The app bundles the native binaries
/// as resources, then copies them to Application Support before execution so
/// subprocess paths are writable/stable across signed app updates.
enum SherpaOnnxRuntime {
    static func installedRuntime(executableName: String) throws -> (binary: URL, libDir: URL) {
        guard let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("sherpa-onnx", isDirectory: true),
              FileManager.default.fileExists(
                atPath: bundled.appendingPathComponent(executableName).path)
        else { throw RuntimeError.missing(executableName) }

        let installed = AppDirectories.applicationSupport
            .appendingPathComponent("sherpa-onnx", isDirectory: true)
        let binary = installed.appendingPathComponent(executableName)

        if needsInstall(from: bundled, to: installed, executableName: executableName) {
            try? FileManager.default.removeItem(at: installed)
            try FileManager.default.createDirectory(
                at: AppDirectories.applicationSupport,
                withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled, to: installed)
            try markExecutables(in: installed)
        }
        return (binary, installed)
    }

    private static func needsInstall(from bundled: URL, to installed: URL,
                                     executableName: String) -> Bool {
        let installedBinary = installed.appendingPathComponent(executableName)
        guard FileManager.default.fileExists(atPath: installedBinary.path) else {
            return true
        }
        let bundledSize = fileSize(bundled.appendingPathComponent(executableName))
        let installedSize = fileSize(installedBinary)
        return bundledSize != installedSize
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    private static func markExecutables(in dir: URL) throws {
        let names = ["sherpa-onnx-offline", "sherpa-onnx-offline-tts"]
        for name in names {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: url.path)
            }
        }
    }

    enum RuntimeError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let executable):
                "The bundled sherpa-onnx runtime is missing \(executable)."
            }
        }
    }
}

enum ArchiveExtractor {
    static func extractBzip2Tar(_ archive: URL, into dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", dir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExtractionError.failed(process.terminationStatus)
        }
    }

    enum ExtractionError: LocalizedError {
        case failed(Int32)

        var errorDescription: String? {
            switch self {
            case .failed(let code): "Could not extract model archive (tar exited \(code))."
            }
        }
    }
}
