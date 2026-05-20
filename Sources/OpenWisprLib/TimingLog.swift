import Foundation

enum TimingLog {
    static let fileURL = Config.configDir.appendingPathComponent("timing.log")

    private static let queue = DispatchQueue(label: "open-wispr.timing-log")

    static func write(_ message: String) {
        print(message)

        queue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: Config.configDir,
                    withIntermediateDirectories: true
                )

                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }

                let timestamp = ISO8601DateFormatter().string(from: Date())
                guard let data = "\(timestamp) \(message)\n".data(using: .utf8) else { return }

                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                print("Warning: failed to write timing log: \(error.localizedDescription)")
            }
        }
    }
}
