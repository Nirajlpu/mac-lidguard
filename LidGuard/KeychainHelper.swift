//
//  KeychainHelper.swift
//  LidGuard
//
//  Credential storage using UserDefaults with obfuscation.
//  During development, the macOS Keychain prompts for password on every
//  rebuild (since the binary signature changes). UserDefaults avoids
//  this entirely. Values are base64-encoded to prevent casual reading.
//
//  Note: For a production/distributed app, consider migrating to Keychain
//  with a proper developer certificate that maintains a stable signature.
//

import Foundation

// MARK: - Keychain Keys

enum KeychainKey: String, CaseIterable {
    case telegramBotToken   = "telegram_bot_token"
    case telegramChatID     = "telegram_chat_id"
    case smtpHost           = "smtp_host"
    case smtpPort           = "smtp_port"
    case smtpUser           = "smtp_user"
    case smtpPassword       = "smtp_password"
    case smtpRecipient      = "smtp_recipient"
}

// MARK: - KeychainHelper

final class KeychainHelper {

    static let shared = KeychainHelper()
    private let prefix = "com.niraj.LidGuard."

    private init() {}

    // MARK: - Save

    /// Saves a string value (base64-encoded for basic obfuscation).
    @discardableResult
    func save(_ value: String, for key: KeychainKey) -> Bool {
        let encoded = Data(value.utf8).base64EncodedString()
        UserDefaults.standard.set(encoded, forKey: prefix + key.rawValue)
        return true
    }

    // MARK: - Read

    /// Retrieves a string value, or nil if not found.
    func read(_ key: KeychainKey) -> String? {
        guard let encoded = UserDefaults.standard.string(forKey: prefix + key.rawValue),
              let data = Data(base64Encoded: encoded),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    // MARK: - Delete

    /// Removes a value.
    @discardableResult
    func delete(_ key: KeychainKey) -> Bool {
        UserDefaults.standard.removeObject(forKey: prefix + key.rawValue)
        return true
    }
}
