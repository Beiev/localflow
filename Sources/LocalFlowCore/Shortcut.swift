import Foundation

/// A user-definable global shortcut: an exact modifier set plus a HID keycode.
/// Only the standard modifier bits are stored; matching additionally requires the
/// physical left ⌘ key for command-containing shortcuts, so the same key held with
/// the right ⌘ still reaches applications (⌘B keeps working as Bold everywhere).
public struct ShortcutSpec: Codable, Equatable, Sendable {
    public var keyCode: Int64
    public var flags: UInt64

    public static let shift: UInt64 = 1 << 17
    public static let control: UInt64 = 1 << 18
    public static let option: UInt64 = 1 << 19
    public static let command: UInt64 = 1 << 20
    static let leftCommandDevice: UInt64 = 0x8
    static let modifiers: UInt64 = shift | control | option | command

    public init(keyCode: Int64, flags: UInt64) {
        self.keyCode = keyCode
        self.flags = flags & Self.modifiers
    }

    public static let dictationDefault = ShortcutSpec(keyCode: 11, flags: command)        // ⌘B
    public static let meetingDefault = ShortcutSpec(keyCode: 46, flags: command | shift)  // ⇧⌘M

    public func matches(keyCode: Int64, rawFlags: UInt64) -> Bool {
        guard keyCode == self.keyCode, rawFlags & Self.modifiers == flags else { return false }
        if flags & Self.command != 0, rawFlags & Self.leftCommandDevice == 0 { return false }
        return true
    }

    /// Shortcuts every application depends on; LocalFlow must not swallow them.
    public var isSystemCritical: Bool {
        let commandOnly = flags == Self.command
        let critical: Set<Int64> = [7, 8, 9, 12, 13, 48, 49] // X, C, V, Q, W, Tab, Space
        return commandOnly && critical.contains(keyCode)
    }

    /// Function keys may act without modifiers; plain letters and digits may not.
    public var isValidChoice: Bool { flags != 0 || Self.functionKeys[keyCode] != nil }

    /// Label like "⇧⌘M" or "⌥F5", in the order macOS uses.
    public var label: String {
        var parts: [String] = []
        if flags & Self.control != 0 { parts.append("⌃") }
        if flags & Self.option != 0 { parts.append("⌥") }
        if flags & Self.shift != 0 { parts.append("⇧") }
        if flags & Self.command != 0 { parts.append("⌘") }
        parts.append(Self.keyName(keyCode) ?? "#\(keyCode)")
        return parts.joined()
    }

    // ANSI names; macOS displays ⌘-combinations layout-independently, so the
    // physical key name is the right rendering regardless of the input source.
    static let ansiKeys: [Int64: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
    ]
    static let functionKeys: [Int64: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    static let specialKeys: [Int64: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    public static func keyName(_ keyCode: Int64) -> String? {
        ansiKeys[keyCode] ?? functionKeys[keyCode] ?? specialKeys[keyCode]
    }

    /// Stored as "flags,keyCode" in UserDefaults; anything unparsible falls back.
    public static func load(key: String, default spec: ShortcutSpec) -> ShortcutSpec {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return spec }
        let parts = raw.split(separator: ",")
        guard parts.count == 2, let flags = UInt64(parts[0]), let keyCode = Int64(parts[1]) else { return spec }
        return ShortcutSpec(keyCode: keyCode, flags: flags)
    }
    public func save(key: String) { UserDefaults.standard.set("\(flags),\(keyCode)", forKey: key) }
    public static func reset(key: String) { UserDefaults.standard.removeObject(forKey: key) }
}
