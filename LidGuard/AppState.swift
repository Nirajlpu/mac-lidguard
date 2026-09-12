//
//  AppState.swift
//  LidGuard
//
//  Central observable state manager that orchestrates the entire
//  wake → capture → geolocate → save → dispatch pipeline.
//

import Foundation
import SwiftUI
import Combine

// MARK: - LogEntry

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let triggerType: String          // "Wake", "Lid Open", "Manual Test"
    var status: DispatchStatus
    var photoPath: String?
    var telegramStatus: String?
    var emailStatus: String?

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

enum DispatchStatus: String {
    case inProgress = "In Progress…"
    case success    = "✅ Success"
    case partial    = "⚠️ Partial"
    case failed     = "❌ Failed"
    case captured   = "📸 Captured"
}

// MARK: - AppState

final class AppState: ObservableObject {

    // MARK: Published Properties

    @Published var isMonitoring: Bool {
        didSet {
            UserDefaults.standard.set(isMonitoring, forKey: "isMonitoring")
            if isMonitoring {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    @Published var useiCloud: Bool {
        didSet {
            UserDefaults.standard.set(useiCloud, forKey: "useiCloud")
        }
    }

    @Published var wakeOnLidOpen: Bool {
        didSet {
            UserDefaults.standard.set(wakeOnLidOpen, forKey: "wakeOnLidOpen")
        }
    }

    @Published var wakeOnFailedLogin: Bool {
        didSet {
            UserDefaults.standard.set(wakeOnFailedLogin, forKey: "wakeOnFailedLogin")
        }
    }

    @Published var logEntries: [LogEntry] = []

    // MARK: Services

    private let wakeWatcher = WakeWatcher()
    private let captureManager = CaptureManager.shared
    private let locationService = LocationService.shared
    private let dispatcher = DispatcherService.shared

    // MARK: Init

    init() {
        self.isMonitoring = UserDefaults.standard.bool(forKey: "isMonitoring")
        self.useiCloud = UserDefaults.standard.object(forKey: "useiCloud") as? Bool ?? true
        self.wakeOnLidOpen = UserDefaults.standard.object(forKey: "wakeOnLidOpen") as? Bool ?? true
        self.wakeOnFailedLogin = UserDefaults.standard.object(forKey: "wakeOnFailedLogin") as? Bool ?? true

        if isMonitoring {
            startMonitoring()
        }
    }

    // MARK: - Monitoring Control

    private func startMonitoring() {
        wakeWatcher.start { [weak self] triggerType in
            self?.handleWakeEvent(triggerType: triggerType)
        }
    }

    private func stopMonitoring() {
        wakeWatcher.stop()
    }

    // MARK: - Wake Event Handler

    /// Full pipeline: delay → capture → geolocate → save → dispatch.
    /// Checks per-trigger toggles before proceeding.
    func handleWakeEvent(triggerType: String) {
        // Filter by trigger toggle
        if triggerType == "Wake / Lid Open" && !wakeOnLidOpen {
            print("[AppState] Ignoring \(triggerType) — lid open trigger disabled.")
            return
        }
        if triggerType == "Failed Login Attempt" && !wakeOnFailedLogin {
            print("[AppState] Ignoring \(triggerType) — failed login trigger disabled.")
            return
        }
        Task { @MainActor in
            let entry = LogEntry(
                timestamp: Date(),
                triggerType: triggerType,
                status: .inProgress
            )
            logEntries.insert(entry, at: 0)

            // Keep log to last 50 entries
            if logEntries.count > 50 {
                logEntries = Array(logEntries.prefix(50))
            }

            let entryIndex = 0

            do {
                // 1. Capture photo
                print("[AppState] Capturing photo...")
                let imageData = try await captureManager.capturePhoto()
                logEntries[entryIndex].status = .captured

                // 2. Generate timestamp string
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let timestampStr = formatter.string(from: Date())

                // 3. Save image to disk
                let savedPath = saveImage(data: imageData, timestamp: timestampStr)
                logEntries[entryIndex].photoPath = savedPath

                // 4. Fetch location (async, non-blocking)
                let location = await locationService.fetchLocation()

                // 5. Dispatch alerts
                let result = await dispatcher.dispatch(
                    imageData: imageData,
                    timestamp: timestampStr,
                    location: location,
                    triggerType: triggerType
                )

                // 6. Update log entry
                logEntries[entryIndex].telegramStatus = result.telegramSuccess
                    ? "✅ Sent" : "❌ \(result.telegramError ?? "Failed")"
                logEntries[entryIndex].emailStatus = result.emailSuccess
                    ? "✅ Sent" : "❌ \(result.emailError ?? "Failed")"

                if result.telegramSuccess && result.emailSuccess {
                    logEntries[entryIndex].status = .success
                } else if result.telegramSuccess || result.emailSuccess {
                    logEntries[entryIndex].status = .partial
                } else {
                    logEntries[entryIndex].status = .failed
                }

                print("[AppState] Pipeline complete. Status: \(logEntries[entryIndex].status.rawValue)")

            } catch {
                print("[AppState] ❌ Pipeline error: \(error.localizedDescription)")
                logEntries[entryIndex].status = .failed
                logEntries[entryIndex].telegramStatus = "❌ \(error.localizedDescription)"
                logEntries[entryIndex].emailStatus = "❌ Not attempted"
            }
        }
    }

    // MARK: - Image Storage

    /// Saves JPEG to iCloud Drive or local fallback. Returns the file path.
    private func saveImage(data: Data, timestamp: String) -> String {
        let filename = "LidGuard_\(timestamp).jpg"

        // Primary: iCloud Drive
        let iCloudPath = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/LidGuard"
        // Fallback: ~/Pictures/LidGuard
        let localPath = NSHomeDirectory() + "/Pictures/LidGuard"

        let targetDir: String
        if useiCloud && FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs") {
            targetDir = iCloudPath
        } else {
            targetDir = localPath
        }

        do {
            try FileManager.default.createDirectory(
                atPath: targetDir,
                withIntermediateDirectories: true,
                attributes: nil
            )

            let filePath = (targetDir as NSString).appendingPathComponent(filename)
            try data.write(to: URL(fileURLWithPath: filePath))
            print("[AppState] 💾 Image saved: \(filePath)")
            return filePath

        } catch {
            print("[AppState] ⚠️ Failed to save image: \(error.localizedDescription)")
            // Emergency fallback to /tmp
            let tmpPath = "/tmp/LidGuard_\(timestamp).jpg"
            try? data.write(to: URL(fileURLWithPath: tmpPath))
            return tmpPath
        }
    }

    // MARK: - Manual Test

    /// Triggers a manual test capture & dispatch cycle.
    func testCaptureNow() {
        handleWakeEvent(triggerType: "Manual Test")
    }
}
