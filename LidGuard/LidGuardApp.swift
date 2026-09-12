//
//  LidGuardApp.swift
//  LidGuard
//
//  Menu bar resident security utility. Monitors wake/lid-open events,
//  captures photos, and dispatches alerts via Telegram & Email.
//
//  macOS 13.0+ (Ventura, Sonoma, Sequoia)
//

import SwiftUI
import AVFoundation
import CoreLocation

@main
struct LidGuardApp: App {

    @StateObject private var appState = AppState()
    @State private var selectedTab = 0

    init() {
        // Trigger LocationService init early to request GPS permission
        _ = LocationService.shared
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(appState: appState)
                .frame(width: 380, height: 480)
        } label: {
            Label("LidGuard", systemImage: "lock.shield.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar Popover

struct MenuBarPopover: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Navigation tabs
            Picker("", selection: $selectedTab) {
                Label("Monitor", systemImage: "eye.fill").tag(0)
                Label("Settings", systemImage: "gearshape.fill").tag(1)
                Label("Log", systemImage: "list.bullet.rectangle.fill").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Tab content
            Group {
                switch selectedTab {
                case 0:
                    monitorTab
                case 1:
                    SettingsView()
                        .environmentObject(appState)
                case 2:
                    LogView()
                        .environmentObject(appState)
                default:
                    EmptyView()
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Footer
            footerView
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.linearGradient(
                    colors: [.blue, .cyan],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            VStack(alignment: .leading, spacing: 1) {
                Text("LidGuard")
                    .font(.headline)
                Text(appState.isMonitoring ? "🟢 Active" : "🔴 Inactive")
                    .font(.caption)
                    .foregroundColor(appState.isMonitoring ? .green : .red)
            }

            Spacer()

            Toggle("", isOn: $appState.isMonitoring)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Monitor Tab

    private var monitorTab: some View {
        VStack(spacing: 16) {
            Spacer()

            // Status icon
            Image(systemName: appState.isMonitoring ? "eye.fill" : "eye.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(appState.isMonitoring
                    ? .linearGradient(colors: [.green, .cyan], startPoint: .top, endPoint: .bottom)
                    : .linearGradient(colors: [.gray, .secondary], startPoint: .top, endPoint: .bottom)
                )

            Text(appState.isMonitoring
                 ? "Monitoring active.\nLidGuard will capture a photo on wake."
                 : "Monitoring disabled.\nToggle the switch above to start.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Test capture button
            Button {
                appState.testCaptureNow()
            } label: {
                Label("Test Capture Now", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)

            // Camera status
            cameraStatusView

            Spacer()
        }
        .padding(12)
    }

    private var cameraStatusView: some View {
        HStack(spacing: 6) {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Camera access granted")
            case .notDetermined:
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.orange)
                Text("Camera permission needed")
            case .denied, .restricted:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text("Camera access denied — open System Settings")
            @unknown default:
                EmptyView()
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Text("v1.0")
                .font(.caption2)
                .foregroundColor(.secondary)

            Spacer()

            Button("Quit LidGuard") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
