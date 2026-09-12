//
//  LogView.swift
//  LidGuard
//
//  Displays a scrollable list of recent capture events with
//  timestamps, dispatch statuses, and quick Finder access.
//

import SwiftUI

struct LogView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Event Log")
                    .font(.headline)
                Spacer()
                if !appState.logEntries.isEmpty {
                    Button("Clear") {
                        appState.logEntries.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if appState.logEntries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No events captured yet.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Text("Events will appear here when the Mac wakes\nor when you use \"Test Capture Now\".")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(appState.logEntries) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: timestamp + trigger type
            HStack {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                    .font(.caption)

                Text(entry.formattedTimestamp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)

                Text("•")
                    .foregroundColor(.secondary)

                Text(entry.triggerType)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(entry.status.rawValue)
                    .font(.caption2)
            }

            // Dispatch details
            HStack(spacing: 12) {
                if let telegram = entry.telegramStatus {
                    Label(telegram, systemImage: "paperplane.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let email = entry.emailStatus {
                    Label(email, systemImage: "envelope.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Open in Finder button
            if let path = entry.photoPath {
                Button {
                    let url = URL(fileURLWithPath: path)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var iconName: String {
        switch entry.status {
        case .success:    return "checkmark.circle.fill"
        case .partial:    return "exclamationmark.triangle.fill"
        case .failed:     return "xmark.circle.fill"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case .captured:   return "camera.fill"
        }
    }

    private var iconColor: Color {
        switch entry.status {
        case .success:    return .green
        case .partial:    return .orange
        case .failed:     return .red
        case .inProgress: return .blue
        case .captured:   return .purple
        }
    }
}
