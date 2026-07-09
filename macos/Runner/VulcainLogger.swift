import Foundation

/// Centralized file logger shared between the main app (VpnManager.swift)
/// and the PacketTunnelMac extension (PacketTunnelProvider.swift). Direct
/// port of ios/Runner/VulcainLogger.swift — only the App Group identifier
/// changed (macOS uses its own App Group, separate from iOS).
///
/// This file must be added to BOTH targets' Compile Sources — see
/// wire_macos_swift_and_framework.rb, which wires that up via xcodeproj.
struct VulcainLogger {
    private static let appGroup = "group.com.vulcainvpn.app.macos"
    private static let logFileName = "vulcain_diagnostic.log"
    private static let stderrFileName = "libbox_stderr.log"
    private static let maxLogSizeBytes = 2 * 1024 * 1024 // 2MB safety cap
    private static let retentionHours: Double = 48

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static var logFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(logFileName)
    }

    private static var stderrFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(stderrFileName)
    }

    /// Log a message. `source` distinguishes which process wrote it —
    /// use "MainApp" from VpnManager.swift, "Extension" from
    /// PacketTunnelProvider.swift.
    static func log(_ source: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(source)] \(message)\n"
        write(line)
    }

    static func error(_ source: String, _ message: String) {
        log(source, "❌ ERROR: \(message)")
    }

    private static func write(_ line: String) {
        guard let url = logFileURL else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }

        trimIfNeeded()
    }

    private static func trimIfNeeded() {
        guard let url = logFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > maxLogSizeBytes,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }

        let lines = content.components(separatedBy: "\n")
        let keep = lines.suffix(lines.count / 2)
        try? keep.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Returns the full log content, or nil if nothing logged yet. Appends
    /// libbox's redirected stderr (Go panic traces, if any occurred) at
    /// the end.
    static func readAll() -> String? {
        guard let url = logFileURL else { return nil }
        let mainLog = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        var stderrSection = ""
        if let stderrURL = stderrFileURL,
           let stderrContent = try? String(contentsOf: stderrURL, encoding: .utf8),
           !stderrContent.isEmpty {
            stderrSection = "\n\n--- libbox stderr (Go runtime output, incl. panic traces) ---\n\(stderrContent)"
        }

        let combined = mainLog + stderrSection
        return combined.isEmpty ? nil : combined
    }

    static func sizeKB() -> Int {
        guard let url = logFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else {
            return 0
        }
        return size / 1024
    }

    static func clear() {
        guard let url = logFileURL else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }
}
