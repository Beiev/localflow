import AppKit
import ApplicationServices
import LocalFlowCore

@MainActor
final class GlobalShortcut {
    private var tap: CFMachPort?
    private var runSource: CFRunLoopSource?
    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    var recording = false
    var enabled = false
    func install() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }; return Unmanaged.passUnretained(event) }
                guard owner.enabled else { return Unmanaged.passUnretained(event) }
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                if key == 11 && CGEventSource.keyState(.combinedSessionState, key: 55) && !event.flags.contains(.maskAlternate) && !event.flags.contains(.maskControl) && !event.flags.contains(.maskShift) {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { owner.onToggle?() }; return nil
                }
                if key == 53 && owner.recording { owner.onCancel?(); return nil }
                return Unmanaged.passUnretained(event)
            }
        }, userInfo: pointer)
        guard let tap else { return false }
        runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func requestPermission() { let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary; _ = AXIsProcessTrustedWithOptions(options) }
}
@MainActor
final class TextInsertion {
    struct Target { let pid: pid_t; let field: AXUIElement }
    private var target: Target?
    func capture() { target = Self.focused() }
    private static func focused() -> Target? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let field = value as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &role)
        guard role as? String != kAXSecureTextFieldSubrole as String else { return nil }
        return Target(pid: app.processIdentifier, field: field)
    }
    func paste(_ text: String, useCurrentTarget: Bool = false) async -> Bool {
        guard !text.isEmpty, let current = Self.focused(), let expected = useCurrentTarget ? current : target, current.pid == expected.pid, CFEqual(current.field, expected.field) else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(current.field, kAXRoleAttribute as CFString, &role)
        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(role as? String ?? "") else { return false }
        var before: CFTypeRef?
        AXUIElementCopyAttributeValue(current.field, kAXValueAttribute as CFString, &before)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return false }
        let pasteboard = NSPasteboard.general
        let old = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in let copy = NSPasteboardItem(); for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }; return copy } ?? []
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let count = pasteboard.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(350))
        if pasteboard.changeCount == count { pasteboard.clearContents(); pasteboard.writeObjects(old) }
        var after: CFTypeRef?
        AXUIElementCopyAttributeValue(current.field, kAXValueAttribute as CFString, &after)
        // Keep the result available if the application cannot confirm the insertion.
        guard let newValue = after as? String else { return false }
        return newValue != before as? String && newValue.contains(text)
    }
}
@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    func show(model: AppModel) {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 190), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true; panel.delegate = self
            panel.contentView = NSHostingView(rootView: OverlayView(model: model))
            self.panel = panel
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let saved = UserDefaults.standard.string(forKey: "overlayOrigin").map(NSPointFromString)
        let origin = saved.flatMap { p in NSScreen.screens.contains { $0.visibleFrame.contains(NSRect(origin: p, size: panel!.frame.size)) } ? p : nil } ?? NSPoint(x: screen.visibleFrame.midX - 220, y: screen.visibleFrame.minY + 32)
        panel?.setFrameOrigin(origin); panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil) }
    func windowDidMove(_ notification: Notification) { if let panel { UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "overlayOrigin") } }
}
import SwiftUI
