//
//  DispatcherService.swift
//  LidGuard
//
//  Alert dispatcher with two pipelines:
//  1. Telegram Bot API (multipart/form-data sendPhoto)
//  2. SMTP Email via curl (reliable TLS handling for Gmail/Outlook)
//
//  Includes a retry queue that watches network connectivity
//  via NWPathMonitor and re-dispatches failed alerts.
//

import Foundation
import Network

// MARK: - DispatchResult

struct DispatchResult: Sendable {
    let telegramSuccess: Bool
    let emailSuccess: Bool
    let telegramError: String?
    let emailError: String?
}

// MARK: - PendingDispatch

private struct PendingDispatch: Sendable {
    let imageData: Data
    let timestamp: String
    let location: LocationInfo
    let triggerType: String
}

// MARK: - DispatcherService

final class DispatcherService: @unchecked Sendable {

    static let shared = DispatcherService()

    private let monitor = NWPathMonitor()
    private var pendingQueue: [PendingDispatch] = []
    private let queueLock = NSLock()
    private var isNetworkAvailable = true

    private init() {
        startNetworkMonitor()
    }

    // MARK: - Network Monitor

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let wasUnavailable = !self.isNetworkAvailable
            self.isNetworkAvailable = (path.status == .satisfied)

            if wasUnavailable && self.isNetworkAvailable {
                print("[DispatcherService] Network restored. Retrying pending dispatches...")
                self.retryPendingDispatches()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    // MARK: - Dispatch All

    /// Dispatches an alert via all configured channels.
    func dispatch(imageData: Data, timestamp: String, location: LocationInfo, triggerType: String = "Unknown") async -> DispatchResult {
        let telegramResult = await sendTelegram(imageData: imageData, timestamp: timestamp, location: location, triggerType: triggerType)
        let emailResult = await sendEmail(imageData: imageData, timestamp: timestamp, location: location, triggerType: triggerType)

        // Queue for retry if both failed due to network
        if !telegramResult.0 && !emailResult.0 && !isNetworkAvailable {
            queueForRetry(imageData: imageData, timestamp: timestamp, location: location, triggerType: triggerType)
        }

        return DispatchResult(
            telegramSuccess: telegramResult.0,
            emailSuccess: emailResult.0,
            telegramError: telegramResult.1,
            emailError: emailResult.1
        )
    }

    // MARK: - Retry Queue

    private func queueForRetry(imageData: Data, timestamp: String, location: LocationInfo, triggerType: String) {
        queueLock.lock()
        pendingQueue.append(PendingDispatch(imageData: imageData, timestamp: timestamp, location: location, triggerType: triggerType))
        queueLock.unlock()
        print("[DispatcherService] Dispatch queued for retry. Queue size: \(pendingQueue.count)")
    }

    private func retryPendingDispatches() {
        queueLock.lock()
        let items = pendingQueue
        pendingQueue.removeAll()
        queueLock.unlock()

        Task {
            for item in items {
                _ = await dispatch(imageData: item.imageData, timestamp: item.timestamp, location: item.location, triggerType: item.triggerType)
            }
        }
    }

    // MARK: - Telegram Pipeline

    /// Sends photo via Telegram Bot API multipart/form-data.
    func sendTelegram(imageData: Data, timestamp: String, location: LocationInfo, triggerType: String = "Unknown") async -> (Bool, String?) {
        let keychain = KeychainHelper.shared
        let token = {
            if let saved = keychain.read(.telegramBotToken), !saved.isEmpty { return saved }
            return "8329610535:AAHkVZKa1dQfylEjsab8LxFudd72Wwqor6M"
        }()
        let chatID = {
            if let saved = keychain.read(.telegramChatID), !saved.isEmpty { return saved }
            return "6222528625"
        }()

        let urlString = "https://api.telegram.org/bot\(token)/sendPhoto"
        guard let url = URL(string: urlString) else {
            return (false, "Invalid Telegram API URL.")
        }

        let triggerEmoji: String
        switch triggerType {
        case "Wake / Lid Open": triggerEmoji = "🚨 Lid Opened / Wake from Sleep"
        case "Failed Login Attempt": triggerEmoji = "🔐 Wrong Password Detected"
        case "Manual Test": triggerEmoji = "🧪 Manual Test Capture"
        default: triggerEmoji = "⚠️ \(triggerType)"
        }

        let caption = """
        🔒 LidGuard Security Alert
        
        🎯 Trigger: \(triggerEmoji)
        ⏰ Time: \(timestamp)
        📡 Location: \(location.locationType)
        🌐 IP: \(location.ip)
        📍 \(location.city), \(location.region), \(location.country)
        🗺 Coords: \(location.loc)
        🏢 ISP: \(location.org)
        📌 Map: \(location.mapsURL)
        """

        let boundary = UUID().uuidString
        var body = Data()

        body.appendMultipartField(name: "chat_id", value: chatID, boundary: boundary)
        body.appendMultipartField(name: "caption", value: caption, boundary: boundary)
        body.appendMultipartFile(
            name: "photo",
            filename: "lidguard_\(timestamp.replacingOccurrences(of: ":", with: "-")).jpg",
            mimeType: "image/jpeg",
            data: imageData,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                print("[DispatcherService] ✅ Telegram alert sent successfully.")
                return (true, nil)
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return (false, "Telegram API returned HTTP \(code)")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - SMTP Email Pipeline (via curl)

    /// Sends an email with JPEG attachment via curl's built-in SMTP support.
    /// curl handles TLS/STARTTLS negotiation reliably with Gmail, Outlook, etc.
    func sendEmail(imageData: Data, timestamp: String, location: LocationInfo, triggerType: String = "Unknown") async -> (Bool, String?) {
        let keychain = KeychainHelper.shared
        guard let host = keychain.read(.smtpHost), !host.isEmpty,
              let portStr = keychain.read(.smtpPort), !portStr.isEmpty,
              let user = keychain.read(.smtpUser), !user.isEmpty,
              let password = keychain.read(.smtpPassword), !password.isEmpty,
              let recipient = keychain.read(.smtpRecipient), !recipient.isEmpty else {
            return (false, "SMTP credentials not configured.")
        }

        let port = UInt16(portStr) ?? 465
        let subject = "🔒 LidGuard Alert — \(triggerType) — \(timestamp)"
        let bodyText = buildEmailBody(timestamp: timestamp, location: location, triggerType: triggerType)
        let imageFilename = "lidguard_\(timestamp.replacingOccurrences(of: ":", with: "-")).jpg"

        // Build MIME message
        let boundary = "LidGuard-\(UUID().uuidString)"
        let base64Image = imageData.base64EncodedString(options: .lineLength76Characters)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let mimeMessage = """
        From: \(user)\r
        To: \(recipient)\r
        Subject: \(subject)\r
        Date: \(dateFormatter.string(from: Date()))\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="\(boundary)"\r
        \r
        --\(boundary)\r
        Content-Type: text/plain; charset="UTF-8"\r
        Content-Transfer-Encoding: 7bit\r
        \r
        \(bodyText)\r
        \r
        --\(boundary)\r
        Content-Type: image/jpeg; name="\(imageFilename)"\r
        Content-Disposition: attachment; filename="\(imageFilename)"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(base64Image)\r
        \r
        --\(boundary)--\r
        """

        // Write MIME message to a temp file for curl
        let tempFile = NSTemporaryDirectory() + "lidguard_email_\(UUID().uuidString).eml"
        do {
            try mimeMessage.write(toFile: tempFile, atomically: true, encoding: .utf8)
        } catch {
            return (false, "Failed to create email file: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        // Determine SMTP URL
        let smtpURL: String
        if port == 465 {
            smtpURL = "smtps://\(host):\(port)"
        } else {
            smtpURL = "smtp://\(host):\(port)"
        }

        // Build curl arguments
        var args = [
            "--url", smtpURL,
            "--mail-from", user,
            "--mail-rcpt", recipient,
            "--user", "\(user):\(password)",
            "--upload-file", tempFile,
            "--silent", "--show-error",
            "--max-time", "30"
        ]
        if port == 587 {
            args.append("--ssl-reqd")
        }

        // Run curl in background
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                process.arguments = args

                let errorPipe = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if process.terminationStatus == 0 {
                        print("[DispatcherService] ✅ Email sent successfully via curl.")
                        continuation.resume(returning: (true, nil))
                    } else {
                        print("[DispatcherService] ❌ curl SMTP failed (exit \(process.terminationStatus)): \(errorOutput)")
                        continuation.resume(returning: (false, errorOutput.isEmpty ? "curl exit code \(process.terminationStatus)" : String(errorOutput.prefix(200))))
                    }
                } catch {
                    continuation.resume(returning: (false, "Failed to run curl: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func buildEmailBody(timestamp: String, location: LocationInfo, triggerType: String) -> String {
        let triggerDesc: String
        switch triggerType {
        case "Wake / Lid Open": triggerDesc = "🚨 Lid Opened / Wake from Sleep"
        case "Failed Login Attempt": triggerDesc = "🔐 Wrong Password Detected"
        case "Manual Test": triggerDesc = "🧪 Manual Test Capture"
        default: triggerDesc = "⚠️ \(triggerType)"
        }

        return """
        LidGuard Security Alert
        ========================
        
        🎯 Trigger:      \(triggerDesc)
        Timestamp:       \(timestamp)
        Location Type:   \(location.locationType)
        Public IP:       \(location.ip)
        Location:        \(location.city), \(location.region), \(location.country)
        Coordinates:     \(location.loc)
        ISP:             \(location.org)
        Timezone:        \(location.timezone)
        
        📌 View on Map: \(location.mapsURL)
        
        A photo was captured from the front-facing camera.
        See attached image for details.
        
        — LidGuard for macOS
        """
    }
}

// MARK: - Data Multipart Helpers

extension Data {
    /// Appends a multipart form-data text field.
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        let fieldString = """
        --\(boundary)\r\n\
        Content-Disposition: form-data; name="\(name)"\r\n\
        \r\n\
        \(value)\r\n
        """
        if let data = fieldString.data(using: .utf8) {
            append(data)
        }
    }

    /// Appends a multipart form-data file field.
    mutating func appendMultipartFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        let header = """
        --\(boundary)\r\n\
        Content-Disposition: form-data; name="\(name)"; filename="\(filename)"\r\n\
        Content-Type: \(mimeType)\r\n\
        \r\n
        """
        if let headerData = header.data(using: .utf8) {
            append(headerData)
        }
        append(data)
        if let crlf = "\r\n".data(using: .utf8) {
            append(crlf)
        }
    }
}
