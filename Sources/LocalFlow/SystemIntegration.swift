import AppKit
import ApplicationServices
import LocalFlowCore

@MainActor
final class GlobalShortcut {
    private var tap: CFMachPort?
    private var runSource: CFRunLoopSource?
    var onToggle: (() -> Void)?
    var onMeeting: (() -> Void)?
    var onCancel: (() -> Void)?
    var recording = false
    var enabled = false
    /// While the user records a new combination in Settings, events pass through.
    var suspended = false
    var dictation = ShortcutSpec.dictationDefault
    var meeting = ShortcutSpec.meetingDefault
    var isInstalled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var permissionStatus: String {
        let trusted = AXIsProcessTrusted()
        if isInstalled { return "⌘B: работает · Универсальный доступ: \(trusted ? "подтверждён" : "macOS пока не подтвердила")" }
        if trusted { return "Универсальный доступ подтверждён, но обработчик клавиш не запущен. Нажмите «Проверить ⌘B»." }
        return "macOS не подтвердила доступ этой сборке. Если LocalFlow уже включён в настройках, удалите его из списка и добавьте заново из ~/Applications/LocalFlow.app."
    }
    func install() -> Bool {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return CGEvent.tapIsEnabled(tap: tap) }
        // Try the protected operation itself: the permission preflight may be stale.
        // macOS still enforces access when creating this event tap.
        let mask = (1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }; return Unmanaged.passUnretained(event) }
                guard owner.enabled, !owner.suspended else { return Unmanaged.passUnretained(event) }
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                if owner.dictation.matches(keyCode: key, rawFlags: event.flags.rawValue) {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { Task { @MainActor in owner.onToggle?() } }; return nil
                }
                if owner.meeting.matches(keyCode: key, rawFlags: event.flags.rawValue) {
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { Task { @MainActor in owner.onMeeting?() } }; return nil
                }
                if key == 53 && owner.recording { Task { @MainActor in owner.onCancel?() }; return nil }
                return Unmanaged.passUnretained(event)
            }
        }, userInfo: pointer)
        guard let tap else { return false }
        runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }
}
@MainActor
final class TextInsertion {
    struct Target { let pid: pid_t; let field: AXUIElement? }
    private var target: Target?
    func capture() { target = Self.focused() }
    private static func focused() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        // The application element is always known; the focused field may not be
        // exposed (browsers, terminals), in which case the paste is delivered blind.
        let base = Target(pid: app.processIdentifier, field: nil)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return base }
        return Target(pid: app.processIdentifier, field: unsafeBitCast(value, to: AXUIElement.self))
    }
    private static func isSecure(_ field: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &role)
        return role as? String == kAXSecureTextFieldSubrole as String
    }
    private static func textValue(_ field: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    /// Pastes into whatever currently holds keyboard focus — that is where the user's
    /// cursor is. Element identity and roles are deliberately not used as gates: web
    /// editors and terminals expose unstable accessibility elements. Native fields are
    /// still verified through their value when they expose one.
    func paste(_ text: String, useCurrentTarget: Bool = false) async -> Bool {
        guard !text.isEmpty, let current = Self.focused() else { return false }
        if let field = current.field, Self.isSecure(field) { return false }
        let before = current.field.flatMap(Self.textValue) ?? ""
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return false }
        let pasteboard = NSPasteboard.general
        let old = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in let copy = NSPasteboardItem(); for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }; return copy } ?? []
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let count = pasteboard.changeCount
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // Slow applications apply the paste asynchronously; give them time and
        // stop waiting once the value provably contains the dictated text.
        let marker = String(text.prefix(80))
        var applied = false
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(200))
            if pasteboard.changeCount != count { break }
            if let value = current.field.flatMap(Self.textValue), value != before, value.contains(marker) { applied = true; break }
        }
        if pasteboard.changeCount == count { pasteboard.clearContents(); pasteboard.writeObjects(old) }
        if applied { return true }
        // Fields that expose plain-string values can be checked; everything else
        // (attributed values, web areas) is trusted once the keystroke was delivered.
        if let after = current.field.flatMap(Self.textValue) { return after != before && after.contains(marker) }
        return true
    }
}
@MainActor
final class OverlayController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var receiptTask: Task<Void, Never>?
    func show(model: AppModel) {
        receiptTask?.cancel()
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 204), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true; panel.delegate = self
            panel.contentView = NSHostingView(rootView: OverlayView(model: model))
            self.panel = panel
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let saved = UserDefaults.standard.string(forKey: "overlayOrigin").map(NSPointFromString)
        let origin = saved.flatMap { p in NSScreen.screens.contains { $0.visibleFrame.contains(NSRect(origin: p, size: panel!.frame.size)) } ? p : nil } ?? NSPoint(x: screen.visibleFrame.midX - 230, y: screen.visibleFrame.minY + 32)
        panel?.setFrameOrigin(origin); panel?.orderFrontRegardless()
    }
    func showReceipt(model: AppModel) {
        show(model: model)
        receiptTask = Task { try? await Task.sleep(for: .seconds(10)); guard !Task.isCancelled else { return }; panel?.orderOut(nil) }
    }
    func hide() { receiptTask?.cancel(); panel?.orderOut(nil) }
    func windowDidMove(_ notification: Notification) { if let panel { UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "overlayOrigin") } }
}
import SwiftUI
