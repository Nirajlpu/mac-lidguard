# 🛡️ LidGuard for macOS

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013.0%2B-blue.svg" alt="macOS 13.0+" />
  <img src="https://img.shields.io/badge/swift-5.9%2B-orange.svg" alt="Swift 5.9+" />
  <img src="https://img.shields.io/badge/ui-SwiftUI%20%2F%20MenuBarExtra-purple.svg" alt="SwiftUI MenuBarExtra" />
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="MIT License" />
</p>

**LidGuard** is a lightweight, menu-bar resident security utility for macOS. It monitors system wake events, lid-open triggers, and failed login attempts. Upon detection, it silently captures a photo using the front-facing camera, resolves precise GPS or IP-based location info, saves the image locally or to iCloud Drive, and dispatches real-time security alerts via **Telegram** and **SMTP Email**.

---

## 🌟 Key Features

- 🚨 **Wake & Lid Open Detection**: Detects system wake and lid openings using `NSWorkspace` notifications and low-level `IOKit` power management routines.
- 🔐 **Failed Login Monitoring**: Automatically detects incorrect password attempts at the lock screen by parsing security events and tracking lock state transitions.
- 📸 **Smart Front-Camera Capture**: Utilizes `AVFoundation` with built-in Image Signal Processor (ISP) warm-up delay (1.5s) to guarantee properly exposed photos immediately upon wake (no black/dark frames).
- 📡 **Dual Geolocation Engine**: Combines high-accuracy `CoreLocation` GPS with an `ipinfo.io` fallback to attach coordinates, city, country, ISP, and Google Maps direct links to every alert.
- ✈️ **Multi-Channel Security Alerts**:
  - **Telegram Bot API**: Instant push notifications with photo attachments and embedded event metadata via multipart POST requests.
  - **SMTP Email**: Direct email alerts with JPEG attachments supporting TLS/STARTTLS for Gmail, Outlook, or custom SMTP servers.
- 🔄 **Offline Resilience & Retry Queue**: Integrates `NWPathMonitor` to queue alerts when offline and automatically dispatches them as soon as internet connection is restored.
- 🔒 **Keychain Credential Protection**: All sensitive tokens and app passwords are encrypted and stored in the macOS System Keychain using native `SecItem` APIs.
- ☁️ **iCloud & Local Backup**: Automatically archives captured security photos to iCloud Drive (`~/Library/Mobile Documents/.../LidGuard`) or local Pictures (`~/Pictures/LidGuard`).
- 🖥️ **Sleek Menu Bar Interface**: Native macOS menu bar extra featuring active toggle switch, instant manual test capture button, live status indicators, and event log history.

---

## 🏗️ Architecture & Alert Pipeline

```
┌────────────────────────────────────────────────────────────────────────┐
│                          TRIGGER DETECTION                             │
│   • IOKit / NSWorkspace (Wake)    • Unified Log / Lock Screen (Auth)   │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                             CAPTURE ENGINE                             │
│       AVFoundation Front Camera + 1.5s ISP Auto-Exposure Warmup       │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                           GEOLOCATION SERVICE                          │
│          CoreLocation GPS ──(Fallback)──► IPInfo Geolocation           │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                            DISPATCHER SERVICE                          │
│   • Telegram Bot API (Photo Multipart)   • SMTP Email (curl TLS)      │
│   • Offline Retry Queue via NWPathMonitor                             │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 System Requirements

- **Operating System**: macOS 13.0 (Ventura), macOS 14.0 (Sonoma), macOS 15.0 (Sequoia), or later.
- **Hardware**: Mac with a built-in FaceTime HD camera or external USB/Continuity camera.
- **Permissions**: Camera Access & Location Services (requested on first launch).

---

## 🛠️ Build & Installation Guide

### Option 1: Direct Run (Pre-built `.dmg`) 🚀

A pre-built Disk Image (`LidGuard.dmg`) is included directly in this repository for instant installation:

1. **Download `LidGuard.dmg`** directly from the repository root (or [clone the repo](https://github.com/Nirajlpu/mac-lidguard.git)).
2. **Double-click `LidGuard.dmg`** to mount the disk image.
3. **Drag `LidGuard.app`** into your `Applications` folder.
4. Launch **LidGuard** from Applications or Spotlight (`Cmd + Space`).
5. Grant **Camera** and **Location** permissions when prompted on first launch.

---

### Option 2: Build from Source with Xcode

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/Nirajlpu/mac-lidguard.git
   cd mac-lidguard
   ```

2. **Open in Xcode**:
   ```bash
   open LidGuard.xcodeproj
   ```

3. **Build & Run**:
   - Select the target `LidGuard` and build scheme.
   - Press `Cmd + R` to run the app.
   - Grant **Camera** and **Location** permissions when prompted.

---

## ⚙️ Configuration & Setup

### 1. Telegram Notifications

To receive alerts on your phone via Telegram:

1. Open Telegram and search for `@BotFather`.
2. Send `/newbot` to create a bot and copy the **Bot Token** provided.
3. Open Telegram and search for `@userinfobot` or start a chat with your new bot and send a message.
4. Obtain your **Chat ID**.
5. In LidGuard, click the Menu Bar icon ➔ **Settings** ➔ **Telegram**.
6. Paste your **Bot Token** and **Chat ID**, click **Save**, then click **Test Alert**.

### 2. SMTP Email Notifications

To receive alerts in your email inbox:

- **Gmail**:
  1. Enable 2-Step Verification on your Google Account.
  2. Generate an App Password at `myaccount.google.com/apppasswords`.
  3. Set Host: `smtp.gmail.com`, Port: `587` (or `465`), User: your Gmail address, Password: the 16-character App Password.
- **Outlook / Office 365**:
  - Host: `smtp.office365.com`, Port: `587`.
- In LidGuard, click **Settings** ➔ **Email**, enter your credentials, click **Save**, and send a **Test Email**.

---

## 📂 Project Structure

```
LidGuard/
├── LidGuard/
│   ├── LidGuardApp.swift       # Application entry point & SwiftUI MenuBarExtra UI
│   ├── AppState.swift          # Core state manager orchestrating wake-to-dispatch flow
│   ├── WakeWatcher.swift       # IOKit & NSWorkspace event listener & failed login detector
│   ├── CaptureManager.swift    # AVFoundation camera session manager with warm-up delay
│   ├── LocationService.swift   # CoreLocation GPS with ipinfo.io IP fallback engine
│   ├── DispatcherService.swift# Telegram Bot API & SMTP email dispatching + offline queue
│   ├── KeychainHelper.swift    # Secure macOS Keychain wrapper for tokens and credentials
│   ├── SettingsView.swift      # User preferences UI (Telegram, Email, Storage, Triggers)
│   └── LogView.swift           # Scrollable audit log of recent capture events
├── LidGuard.xcodeproj          # Xcode project file
└── README.md                   # Project documentation
```

---

## 🔒 Privacy & Security

- **Data Privacy**: All captured images and location coordinates are stored locally on your device or in your personal iCloud Drive. No data is sent to external servers other than your configured Telegram Bot and SMTP email endpoints.
- **Credential Storage**: API tokens and email passwords are stored exclusively inside the encrypted macOS System Keychain using standard Apple Security APIs.

---

## 📄 License

Distributed under the **MIT License**. See `LICENSE` for more information.
