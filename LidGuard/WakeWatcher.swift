//
//  WakeWatcher.swift
//  LidGuard
//
//  Monitors three event sources:
//  1. NSWorkspace.didWakeNotification (system wake from sleep)
//  2. IOKit power notifications (lid open / clamshell transitions)
//  3. Lock screen activity detection via DistributedNotificationCenter
//     — captures when someone interacts with the lock screen (wrong password scenario)
//
//  Implements 10-second debouncing to prevent burst captures.
//

import Foundation
import AppKit
import IOKit
import IOKit.pwr_mgt

// MARK: - IOKit Message Constants
// These are C macros that Swift cannot import directly, so we define
// their raw UInt32 values here. Values from IOMessage.h:
//   kIOMessageSystemHasPoweredOn  = 0xe0000300
//   kIOMessageCanSystemSleep      = 0xe0000270
//   kIOMessageSystemWillSleep     = 0xe0000280

private let kIOMessageSystemHasPoweredOnValue:  UInt32 = 0xe000_0300
private let kIOMessageCanSystemSleepValue:      UInt32 = 0xe000_0270
private let kIOMessageSystemWillSleepValue:     UInt32 = 0xe000_0280

// MARK: - WakeWatcher

final class WakeWatcher: @unchecked Sendable {

    // MARK: - Properties

    private var onWake: ((String) -> Void)?   // callback with trigger type
    private var notificationPort: IONotificationPortRef?
    private var notifierObject: io_object_t = IO_OBJECT_NULL
    private var rootPort: io_connect_t = IO_OBJECT_NULL

    private let debounceInterval: TimeInterval = 10.0
    private var lastTriggerDate: Date = .distantPast
    private let lock = NSLock()

    // Failed login monitor
    private var logStreamProcess: Process?
    private var logStreamPipe: Pipe?
    
    // Lock screen state tracking
    private var isScreenLocked = false
    private var lockScreenTimer: Timer?
    private var lockTimestamp: Date = .distantPast
    private let lockGracePeriod: TimeInterval = 8.0  // ignore auth activity this long after lock

    // MARK: - Init / Deinit

    init() {}

    deinit {
        stop()
    }

    // MARK: - Start Monitoring

    /// Begins watching for system wake events and failed login attempts.
    /// - Parameter handler: Called on each debounced event with the trigger type string.
    func start(onWake handler: @escaping (String) -> Void) {
        self.onWake = handler
        registerNSWorkspaceNotifications()
        registerIOKitPowerNotifications()
        startLockScreenMonitor()
        startFailedLoginLogMonitor()
        print("[WakeWatcher] Monitoring started (wake + lock screen + failed logins).")
    }

    // MARK: - Stop Monitoring

    func stop() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)

        if notifierObject != IO_OBJECT_NULL {
            IODeregisterForSystemPower(&notifierObject)
            notifierObject = IO_OBJECT_NULL
        }

        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }

        if rootPort != IO_OBJECT_NULL {
            IOServiceClose(rootPort)
            rootPort = IO_OBJECT_NULL
        }

        lockScreenTimer?.invalidate()
        lockScreenTimer = nil
        stopFailedLoginLogMonitor()

        onWake = nil
        print("[WakeWatcher] Monitoring stopped.")
    }

    // MARK: - NSWorkspace Notifications

    private func registerNSWorkspaceNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWorkspaceWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleWorkspaceWake(_ notification: Notification) {
        print("[WakeWatcher] NSWorkspace.didWakeNotification received.")
        // Reset grace period so SecurityAgent startup after wake is ignored
        lock.lock()
        lockTimestamp = Date()
        lockScreenTimer?.invalidate()
        lockScreenTimer = nil
        lock.unlock()
        fireDebouncedWake(triggerType: "Wake / Lid Open")
    }

    // MARK: - IOKit Power Notifications

    private func registerIOKitPowerNotifications() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        rootPort = IORegisterForSystemPower(
            refcon,
            &notificationPort,
            ioKitPowerCallback,
            &notifierObject
        )

        guard rootPort != IO_OBJECT_NULL else {
            print("[WakeWatcher] ⚠️ Failed to register for IOKit system power notifications.")
            return
        }

        if let port = notificationPort {
            IONotificationPortSetDispatchQueue(port, DispatchQueue.global(qos: .utility))
        }

        print("[WakeWatcher] IOKit power notifications registered.")
    }

    // MARK: - Lock Screen Monitor (DistributedNotificationCenter)
    //
    // Strategy: When the screen locks, we start a timer that fires once after
    // a short delay. If the screen is unlocked (correct password) before the
    // timer fires, we cancel it — no photo taken. If the timer fires while
    // the screen is STILL locked, it means someone failed to authenticate
    // (entered wrong password or the lock screen is just sitting there),
    // so we capture a photo.
    //
    // This is the most reliable non-root approach on macOS because the
    // unified log auth events require elevated privileges.

    private func startLockScreenMonitor() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenLocked(_:)),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenUnlocked(_:)),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        print("[WakeWatcher] Lock screen monitor started.")
    }

    @objc private func handleScreenLocked(_ notification: Notification) {
        lock.lock()
        isScreenLocked = true
        lockTimestamp = Date()
        lock.unlock()
        print("[WakeWatcher] 🔒 Screen locked — ignoring auth activity for \(lockGracePeriod)s grace period.")
    }

    @objc private func handleScreenUnlocked(_ notification: Notification) {
        lock.lock()
        let wasLocked = isScreenLocked
        isScreenLocked = false
        // Cancel any pending failed-login capture — unlock means correct password
        lockScreenTimer?.invalidate()
        lockScreenTimer = nil
        lock.unlock()

        if wasLocked {
            print("[WakeWatcher] 🔓 Screen unlocked (correct password) — pending capture cancelled.")
        }
    }

    /// Schedules a delayed capture. If the screen unlocks (correct password)
    /// within 5 seconds, the timer is cancelled and no photo is taken.
    /// If the screen stays locked (wrong password), the timer fires.
    private func scheduleFailedLoginCapture() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            // Don't stack multiple timers
            if self.lockScreenTimer != nil {
                self.lock.unlock()
                return
            }
            self.lock.unlock()

            let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.lock.lock()
                let stillLocked = self.isScreenLocked
                self.lockScreenTimer = nil
                self.lock.unlock()

                if stillLocked {
                    print("[WakeWatcher] 🔐 Screen still locked after auth activity — failed login capture.")
                    self.fireDebouncedWake(triggerType: "Failed Login Attempt")
                } else {
                    print("[WakeWatcher] Screen unlocked before timer — no capture needed.")
                }
            }

            self.lock.lock()
            self.lockScreenTimer = timer
            self.lock.unlock()
        }
    }

    // MARK: - Failed Login Log Monitor
    //
    // Monitors the macOS unified log for SecurityAgent / loginwindow / authorizationhost
    // messages. On many macOS versions these events are visible to the current user
    // at `--level debug`. We stream with a broad process-based predicate.

    private func startFailedLoginLogMonitor() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--level", "debug",
            "--style", "compact",
            "--predicate",
            #"process == "SecurityAgent" OR process == "authorizationhost" OR process == "loginwindow" OR subsystem == "com.apple.Authorization" OR subsystem == "com.apple.loginwindow" OR (process == "authd")"#
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // Buffer for accumulating partial reads across chunks
        var lineBuffer = ""

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8) else {
                return
            }

            lineBuffer += chunk
            // Process complete lines
            while let newlineRange = lineBuffer.range(of: "\n") {
                let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
                lineBuffer = String(lineBuffer[newlineRange.upperBound...])

                let lowered = line.lowercased()

                // Skip the header/filter description lines
                if lowered.hasPrefix("filtering") || (lowered.contains("timestamp") && lowered.contains("process")) { continue }
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

                // Detect authentication failure indicators
                let isFailure =
                    (lowered.contains("fail") && (lowered.contains("auth") || lowered.contains("verif") || lowered.contains("credential"))) ||
                    lowered.contains("denied") ||
                    lowered.contains("wrong password") ||
                    lowered.contains("incorrect") ||
                    lowered.contains("password was incorrect") ||
                    lowered.contains("authentication error") ||
                    lowered.contains("reject") ||
                    lowered.contains("la error") ||
                    (lowered.contains("securityagent") && lowered.contains("error"))

                if isFailure {
                    // Only act on failure keywords if past the grace period
                    // (SecurityAgent startup messages often contain "error"/"fail" keywords)
                    self?.lock.lock()
                    let locked = self?.isScreenLocked ?? false
                    let timeSinceLock = Date().timeIntervalSince(self?.lockTimestamp ?? .distantPast)
                    let pastGrace = timeSinceLock > (self?.lockGracePeriod ?? 8.0)
                    self?.lock.unlock()

                    if !locked || pastGrace {
                        print("[WakeWatcher] 🔐 Failed login keyword detected: \(line.prefix(300))")
                        self?.scheduleFailedLoginCapture()
                    }
                }

                // Also detect ANY SecurityAgent auth activity while screen is locked
                // SecurityAgent spawns when the lock screen password field becomes active
                if lowered.contains("securityagent") || lowered.contains("authorizationhost") {
                    self?.lock.lock()
                    let locked = self?.isScreenLocked ?? false
                    let timeSinceLock = Date().timeIntervalSince(self?.lockTimestamp ?? .distantPast)
                    let pastGrace = timeSinceLock > (self?.lockGracePeriod ?? 8.0)
                    self?.lock.unlock()

                    if locked && pastGrace {
                        print("[WakeWatcher] 🔐 Auth activity while screen locked (\(String(format: "%.1f", timeSinceLock))s after lock): \(line.prefix(200))")
                        self?.scheduleFailedLoginCapture()
                    }
                }
            }
        }

        do {
            try process.run()
            self.logStreamProcess = process
            self.logStreamPipe = pipe
            print("[WakeWatcher] Failed login log monitor started (--level debug, broad predicate).")
        } catch {
            print("[WakeWatcher] ⚠️ Failed to start login log monitor: \(error.localizedDescription)")
        }
    }

    private func stopFailedLoginLogMonitor() {
        logStreamPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = logStreamProcess, process.isRunning {
            process.terminate()
        }
        logStreamProcess = nil
        logStreamPipe = nil
    }

    // MARK: - Debounce

    private func fireDebouncedWake(triggerType: String) {
        lock.lock()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTriggerDate)
        guard elapsed >= debounceInterval else {
            lock.unlock()
            print("[WakeWatcher] Debounced — only \(String(format: "%.1f", elapsed))s since last trigger.")
            return
        }
        lastTriggerDate = now
        lock.unlock()

        print("[WakeWatcher] 🔔 Event triggered: \(triggerType)")
        onWake?(triggerType)
    }

    /// Called from the IOKit C callback to process power events.
    fileprivate func handleIOKitPowerEvent(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        switch messageType {
        case kIOMessageSystemHasPoweredOnValue:
            print("[WakeWatcher] IOKit: System has powered on (wake from sleep).")
            // Reset grace period so SecurityAgent startup after wake is ignored
            lock.lock()
            lockTimestamp = Date()
            lockScreenTimer?.invalidate()
            lockScreenTimer = nil
            lock.unlock()
            fireDebouncedWake(triggerType: "Wake / Lid Open")

        case kIOMessageCanSystemSleepValue:
            // Allow sleep
            if let argument = messageArgument {
                IOAllowPowerChange(rootPort, Int(bitPattern: argument))
            }

        case kIOMessageSystemWillSleepValue:
            // Acknowledge impending sleep
            if let argument = messageArgument {
                IOAllowPowerChange(rootPort, Int(bitPattern: argument))
            }

        default:
            break
        }
    }
}

// MARK: - IOKit C Callback

/// Free function compatible with IOKit's C function pointer requirement.
private func ioKitPowerCallback(
    refcon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let watcher = Unmanaged<WakeWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleIOKitPowerEvent(messageType: messageType, messageArgument: messageArgument)
}
