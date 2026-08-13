import SwiftUI

struct StatCardView: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TimeRangePickerView: View {
    @Binding var preset: TimeRangePreset
    @Binding var customStart: Date
    @Binding var customEnd: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Range", selection: $preset) {
                ForEach(TimeRangePreset.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .help("Time range")

            if preset == .custom {
                DatePicker("Start", selection: $customStart, displayedComponents: .date)
                DatePicker("End", selection: $customEnd, displayedComponents: .date)
            }
        }
    }
}

struct AppIconView: View {
    let bundleId: String?
    var size: CGFloat = 20

    var body: some View {
        if let bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app")
                .frame(width: size, height: size)
        }
    }
}

import AppKit
