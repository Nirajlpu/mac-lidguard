//
//  SettingsView.swift
//  LidGuard
//
//  SwiftUI preferences panel for configuring Telegram,
//  SMTP, and storage settings. All credentials are persisted
//  securely in the macOS Keychain.
//

import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("Telegram").tag(0)
                Text("Email").tag(1)
                Text("Storage").tag(2)
                Text("Triggers").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Divider()
                .padding(.top, 8)

            // Tab content
            switch selectedTab {
            case 0:
                TelegramSettingsView()
            case 1:
                SMTPSettingsView()
            case 2:
                StorageSettingsView()
                    .environmentObject(appState)
            case 3:
                TriggersSettingsView()
                    .environmentObject(appState)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Telegram Settings

struct TelegramSettingsView: View {
    @State private var botToken: String = ""
    @State private var chatID: String = ""
    @State private var isTesting: Bool = false
    @State private var testResult: String?

    private let keychain = KeychainHelper.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Telegram Bot Configuration")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Bot Token")
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("123456:ABC-DEF1234ghIkl-zyx57W2v...", text: $botToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Chat ID")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g. 123456789 or -100123456789", text: $chatID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            HStack {
                Button("Save") {
                    keychain.save(botToken, for: .telegramBotToken)
                    keychain.save(chatID, for: .telegramChatID)
                    testResult = "✅ Saved to Keychain."
                }
                .buttonStyle(.borderedProminent)

                Button("Test Alert") {
                    sendTestTelegram()
                }
                .buttonStyle(.bordered)
                .disabled(botToken.isEmpty || chatID.isEmpty || isTesting)

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundColor(result.contains("✅") ? .green : .red)
                    .lineLimit(3)
            }

            Spacer()
        }
        .padding(12)
        .onAppear {
            botToken = keychain.read(.telegramBotToken) ?? ""
            chatID = keychain.read(.telegramChatID) ?? ""
        }
    }

    private func sendTestTelegram() {
        isTesting = true
        testResult = nil

        // Save first
        keychain.save(botToken, for: .telegramBotToken)
        keychain.save(chatID, for: .telegramChatID)

        Task {
            // Create a tiny test image (1x1 red pixel JPEG)
            let testData = createTestImage()
            let result = await DispatcherService.shared.sendTelegram(
                imageData: testData,
                timestamp: "test",
                location: .unknown
            )
            await MainActor.run {
                isTesting = false
                if result.0 {
                    testResult = "✅ Test alert sent successfully!"
                } else {
                    testResult = "❌ \(result.1 ?? "Unknown error")"
                }
            }
        }
    }

    private func createTestImage() -> Data {
        let size = NSSize(width: 100, height: 100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.boldSystemFont(ofSize: 14)
        ]
        "LidGuard\nTest".draw(at: NSPoint(x: 10, y: 40), withAttributes: attrs)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return Data()
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? Data()
    }
}

// MARK: - SMTP Settings

struct SMTPSettingsView: View {
    @State private var smtpHost: String = ""
    @State private var smtpPort: String = "587"
    @State private var smtpUser: String = ""
    @State private var smtpPassword: String = ""
    @State private var smtpRecipient: String = ""
    @State private var isTesting: Bool = false
    @State private var testResult: String?

    private let keychain = KeychainHelper.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("SMTP Email Configuration")
                    .font(.headline)

                Group {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SMTP Host")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("smtp.gmail.com", text: $smtpHost)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Port")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("587 (STARTTLS) or 465 (TLS)", text: $smtpPort)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Username / Email")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("your-email@gmail.com", text: $smtpUser)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("App Password")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("App-specific password", text: $smtpPassword)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recipient Email")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("alert-recipient@example.com", text: $smtpRecipient)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Button("Save") {
                        saveCredentials()
                        testResult = "✅ Saved to Keychain."
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Test Email") {
                        sendTestEmail()
                    }
                    .buttonStyle(.bordered)
                    .disabled(smtpHost.isEmpty || smtpUser.isEmpty || smtpPassword.isEmpty || isTesting)

                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(result.contains("✅") ? .green : .red)
                        .lineLimit(3)
                }
            }
            .padding(12)
        }
        .onAppear {
            smtpHost = keychain.read(.smtpHost) ?? ""
            smtpPort = keychain.read(.smtpPort) ?? "587"
            smtpUser = keychain.read(.smtpUser) ?? ""
            smtpPassword = keychain.read(.smtpPassword) ?? ""
            smtpRecipient = keychain.read(.smtpRecipient) ?? ""
        }
    }

    private func saveCredentials() {
        keychain.save(smtpHost, for: .smtpHost)
        keychain.save(smtpPort, for: .smtpPort)
        keychain.save(smtpUser, for: .smtpUser)
        keychain.save(smtpPassword, for: .smtpPassword)
        keychain.save(smtpRecipient, for: .smtpRecipient)
    }

    private func sendTestEmail() {
        isTesting = true
        testResult = nil
        saveCredentials()

        Task {
            let testData = Data("Test image placeholder".utf8)
            let result = await DispatcherService.shared.sendEmail(
                imageData: testData,
                timestamp: "test",
                location: .unknown
            )
            await MainActor.run {
                isTesting = false
                if result.0 {
                    testResult = "✅ Test email sent successfully!"
                } else {
                    testResult = "❌ \(result.1 ?? "Unknown error")"
                }
            }
        }
    }
}

// MARK: - Storage Settings

struct StorageSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage Configuration")
                .font(.headline)

            Toggle("Save photos to iCloud Drive", isOn: $appState.useiCloud)
                .toggleStyle(.switch)

            if appState.useiCloud {
                HStack(spacing: 4) {
                    Image(systemName: "icloud.fill")
                        .foregroundColor(.blue)
                    Text("~/Library/Mobile Documents/.../LidGuard/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.orange)
                    Text("~/Pictures/LidGuard/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            Button("Open Photos Folder in Finder") {
                openPhotosFolder()
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(12)
    }

    private func openPhotosFolder() {
        let iCloudPath = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/LidGuard"
        let localPath = NSHomeDirectory() + "/Pictures/LidGuard"

        let path = appState.useiCloud && FileManager.default.fileExists(atPath: iCloudPath)
            ? iCloudPath : localPath

        // Create if not exists
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// MARK: - Triggers Settings

struct TriggersSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Capture Triggers")
                .font(.headline)

            Text("Choose which events trigger a photo capture.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            // Lid Open / Wake toggle
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.title3)
                    .foregroundColor(.blue)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Lid Open / Wake from Sleep", isOn: $appState.wakeOnLidOpen)
                        .toggleStyle(.switch)

                    Text("Captures a photo when the Mac wakes from sleep or the lid is opened.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // Failed Login toggle
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .font(.title3)
                    .foregroundColor(.red)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Failed Login Attempt", isOn: $appState.wakeOnFailedLogin)
                        .toggleStyle(.switch)

                    Text("Captures a photo when someone enters a wrong password on the lock screen.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
        .padding(12)
    }
}
