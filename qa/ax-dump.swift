// Prints the accessible name of every control in a process's frontmost window.
//
// System Events cannot read AXAttributedDescription, which is where SwiftUI on
// current macOS puts .accessibilityLabel, so a check for "does this control
// have a name a screen reader would read" needs the API directly.
//
//   qa/ax-dump.swift <process name>

import ApplicationServices
import AppKit

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func text(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = attribute(element, name) else { return nil }
    if let string = value as? String { return string.isEmpty ? nil : string }
    if let attributed = value as? NSAttributedString {
        return attributed.string.isEmpty ? nil : attributed.string
    }
    return nil
}

/// What a screen reader would announce, in the order it looks.
func accessibleName(_ element: AXUIElement) -> String {
    for key in [kAXTitleAttribute as String, kAXDescriptionAttribute as String,
                "AXAttributedDescription", kAXHelpAttribute as String,
                kAXValueAttribute as String] {
        if let found = text(element, key) { return "\(found)  [\(key)]" }
    }
    return "(no accessible name)"
}

func walk(_ element: AXUIElement, depth: Int) {
    let role = text(element, kAXRoleAttribute as String) ?? "?"
    if ["AXButton", "AXTextField", "AXSlider", "AXCheckBox", "AXPopUpButton"].contains(role) {
        var line = String(repeating: "  ", count: depth) + role + ": " + accessibleName(element)
        if let value = text(element, kAXValueAttribute as String), role != "AXTextField" {
            line += "  value=\(value)"
        }
        print(line)
    }
    let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    for child in children { walk(child, depth: depth + 1) }
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("this process is not trusted for accessibility\n".utf8))
    exit(2)
}
let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Doppel"
guard let app = NSWorkspace.shared.runningApplications
    .first(where: { $0.localizedName == name }) else {
    FileHandle.standardError.write(Data("no running process called \(name)\n".utf8))
    exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
guard let windows = attribute(root, kAXWindowsAttribute as String) as? [AXUIElement],
      let window = windows.first else {
    FileHandle.standardError.write(Data("\(name) has no windows open\n".utf8))
    exit(1)
}
print("window: \(text(window, kAXTitleAttribute as String) ?? "(untitled)")")
walk(window, depth: 0)
