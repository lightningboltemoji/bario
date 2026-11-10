import CoreGraphics

/// A key and the modifiers held with it, as `on-click="key fn+n"` writes it: for a click whose
/// job is a keyboard shortcut the system already has. DESIGN.md §8.
///
/// Keys are named by where they sit on a US keyboard, because a virtual key code is a place, not
/// a character: `cmd+z` is the key left of X whatever layout is active. The system's own
/// shortcuts are matched the same way.
public struct KeyChord: Sendable, Equatable, CustomStringConvertible {
    public enum Modifier: String, Sendable, CaseIterable {
        case fn, ctrl, opt, shift, cmd

        static let aliases: [String: Modifier] = [
            "fn": .fn, "globe": .fn,
            "ctrl": .ctrl, "control": .ctrl,
            "opt": .opt, "option": .opt, "alt": .opt,
            "shift": .shift,
            "cmd": .cmd, "command": .cmd,
        ]

        /// The left-hand key, which is the one a flags-changed event names.
        var keyCode: CGKeyCode {
            switch self {
            case .fn: 63
            case .ctrl: 59
            case .opt: 58
            case .shift: 56
            case .cmd: 55
            }
        }

        var flag: CGEventFlags {
            switch self {
            case .fn: .maskSecondaryFn
            case .ctrl: .maskControl
            case .opt: .maskAlternate
            case .shift: .maskShift
            case .cmd: .maskCommand
            }
        }
    }

    /// In the order they were written, which is the order they go down.
    public var modifiers: [Modifier]
    public var key: CGKeyCode
    /// As written, lowercased: what a diagnostic or a log line shows.
    public var text: String

    public var description: String { text }

    /// The system's own shortcut for Notification Center, which opens it or closes it.
    public var togglesNotificationCenter: Bool { modifiers == [.fn] && key == KeyChord.keys["n"] }

    /// `fn+n`, `cmd+shift+4`, `ctrl+left`: modifiers first, the key last, joined by `+`.
    public init(parsing raw: String) throws {
        let text = raw.lowercased()
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last, !parts.contains(where: \.isEmpty) else {
            throw KeyChordError("key takes a chord like fn+n or cmd+shift+4, found \"\(raw)\"")
        }
        var modifiers: [Modifier] = []
        for part in parts.dropLast() {
            guard let modifier = Modifier.aliases[part] else {
                throw KeyChordError("\"\(part)\" in \"\(raw)\" is not a modifier: "
                                    + "fn, ctrl, opt, shift or cmd")
            }
            guard !modifiers.contains(modifier) else {
                throw KeyChordError("\"\(raw)\" holds \(modifier.rawValue) twice")
            }
            modifiers.append(modifier)
        }
        guard let key = KeyChord.keys[name] else {
            if Modifier.aliases[name] != nil {
                throw KeyChordError("\"\(raw)\" is only modifiers: end it with the key they "
                                    + "go with, like fn+n")
            }
            throw KeyChordError("\"\(name)\" in \"\(raw)\" is not a key bario knows: a letter, "
                                + "a digit, f1 to f20, a named key like space or left, or one of "
                                + "- = [ ] ; , . / `")
        }
        self.modifiers = modifiers
        self.key = key
        self.text = text
    }

    /// The chord as a keyboard sends it: each modifier down in turn, the key down and up, then the
    /// modifiers up in reverse, every event carrying the modifiers held at that moment.
    public func events(source: CGEventSource? = nil) -> [CGEvent] {
        var events: [CGEvent] = []
        var flags: CGEventFlags = []
        func add(_ code: CGKeyCode, down: Bool, flagsChanged: Bool = false) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            else { return }
            if flagsChanged { event.type = .flagsChanged }
            event.flags = flags
            events.append(event)
        }
        for modifier in modifiers {
            flags.insert(modifier.flag)
            add(modifier.keyCode, down: true, flagsChanged: true)
        }
        add(key, down: true)
        add(key, down: false)
        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            add(modifier.keyCode, down: false, flagsChanged: true)
        }
        return events
    }

    /// Sends the chord to whatever has keyboard focus, as if typed. It takes Accessibility
    /// permission: without it the events vanish without an error, which is why the caller checks
    /// `CGPreflightPostEventAccess` first.
    public func post() {
        for event in events(source: CGEventSource(stateID: .hidSystemState)) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Virtual key codes, by their place on a US keyboard.
    static let keys: [String: CGKeyCode] = {
        var keys: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "quote": 39, "k": 40, ";": 41, "backslash": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "forward-delete": 117,
            "home": 115, "end": 119, "page-up": 116, "page-down": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let functionKeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                                         103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (index, code) in functionKeys.enumerated() { keys["f\(index + 1)"] = code }
        return keys
    }()
}

public struct KeyChordError: Error, CustomStringConvertible, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// The modifier keys held, as bario keeps them at the root of the store, so a template can say
/// `if "/modifiers.option" { … }` and an open menu that read them renders again when they change
///.
public struct ModifierKeys: Sendable, Equatable {
    public static let storeKey = "modifiers"

    public var option = false
    public var shift = false
    public var control = false
    public var command = false

    public init(option: Bool = false, shift: Bool = false, control: Bool = false, command: Bool = false) {
        self.option = option
        self.shift = shift
        self.control = control
        self.command = command
    }

    public var json: JSONValue {
        .object(["option": .bool(option), "shift": .bool(shift), "control": .bool(control), "command": .bool(command)])
    }
}
