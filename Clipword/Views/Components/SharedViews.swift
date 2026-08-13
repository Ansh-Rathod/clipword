import AppKit
import SwiftUI

@MainActor
enum KeyboardContextMenu {
    private static var keepAlive: MenuActions?

    final class MenuActions: NSObject {
        var handlers: [Int: () -> Void] = [:]

        @objc func invoke(_ sender: NSMenuItem) {
            handlers[sender.tag]?()
        }
    }

    static func popHistory(
        copy: @escaping () -> Void,
        paste: @escaping () -> Void,
        addToStack: @escaping () -> Void,
        edit: @escaping () -> Void,
        toggleBookmark: @escaping () -> Void,
        bookmarkTitle: String,
        togglePin: @escaping () -> Void,
        pinTitle: String,
        delete: @escaping () -> Void
    ) {
        pop(buildMenu { add, separator in
            add("Copy", "c", .command, copy)
            add("Paste", "\r", [], paste)
            add("Add to Paste Stack", "v", [.command, .shift], addToStack)
            separator()
            add("Edit…", "e", .command, edit)
            add(bookmarkTitle, "b", .option, toggleBookmark)
            add(pinTitle, "p", .option, togglePin)
            separator()
            add("Delete", "\u{08}", .command, delete)
        })
    }

    static func popBookmark(
        copy: @escaping () -> Void,
        paste: @escaping () -> Void,
        edit: @escaping () -> Void,
        remove: @escaping () -> Void
    ) {
        pop(buildMenu { add, separator in
            add("Copy", "c", .command, copy)
            add("Paste", "\r", [], paste)
            separator()
            add("Edit…", "e", .command, edit)
            add("Remove Bookmark", "\u{08}", .command, remove)
        })
    }

    private static func buildMenu(
        _ build: (
            _ add: (String, String, NSEvent.ModifierFlags, @escaping () -> Void) -> Void,
            _ separator: () -> Void
        ) -> Void
    ) -> NSMenu {
        let actions = MenuActions()
        keepAlive = actions
        let menu = NSMenu()
        menu.autoenablesItems = false
        var tag = 1

        func add(_ title: String, _ key: String, _ mask: NSEvent.ModifierFlags, _ handler: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuActions.invoke(_:)), keyEquivalent: key)
            item.target = actions
            item.keyEquivalentModifierMask = mask
            item.tag = tag
            actions.handlers[tag] = handler
            tag += 1
            menu.addItem(item)
        }

        build(add, { menu.addItem(.separator()) })
        return menu
    }

    private static func pop(_ menu: NSMenu) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = NSPoint(x: 260, y: view.bounds.midY)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

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
