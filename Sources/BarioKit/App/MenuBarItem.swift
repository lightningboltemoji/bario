import AppKit
import ServiceManagement

/// The menu bar item: the one handle on a bario that was opened from Finder or at login, where
/// there is no terminal to Ctrl-C and no reason to know `killall`. It puts the bars away and
/// brings them back, reloads, opens the config folder, registers the app as a login item, and
/// quits.
///
/// It lives in the real menu bar, under the bars — reached the same way as any other status item,
/// by moving the pointer up until the hole opens. With the bars hidden it is simply there, which
/// is what makes hiding safe: the way back is never covered.
///
/// It holds no state of its own. Everything it shows is read from the controller through the
/// closures below when the menu opens, so it can never disagree with the frame loop.
@MainActor
public final class MenuBarItem: NSObject, NSMenuDelegate {
    /// Whether the bars are put away. Read for the icon and the menu; the controller owns it.
    public var isHidden: () -> Bool = { false }
    /// The config or stylesheet error the bars are showing, if any.
    public var error: () -> String? = { nil }
    /// Where the config lives, or will once it is created.
    public var configDirectory: () -> URL = { ConfigLoader.searchDirectories[0] }

    public var onSetHidden: ((Bool) -> Void)?
    public var onReload: (() -> Void)?

    private let item: NSStatusItem

    public override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        // The version and the diagnostic are disabled items with no action; automatic enabling
        // would fight that.
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    /// Redraw the icon from the controller's state. The menu rebuilds itself when it opens.
    public func refresh() {
        guard let button = item.button else { return }
        let hidden = isHidden()
        let image = NSImage(systemSymbolName: hidden ? "eyeglasses.slash" : "eyeglasses",
                            accessibilityDescription: "bario")
        image?.isTemplate = true
        button.image = image
        button.toolTip = error() != nil ? "bario — config error" : hidden ? "bario — hidden" : "bario"
    }

    /// Rebuilt every time it opens rather than kept in sync: the login item can be switched off in
    /// System Settings, and the error can come and go while the menu is closed.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled("bario \(barioVersion)"))

        if let error = error() {
            menu.addItem(.separator())
            menu.addItem(disabled("Config error — running the last good one"))
            let small = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            for line in MenuBarItem.wrap(error, at: 56) {
                menu.addItem(disabled(line, font: small))
            }
        }
        menu.addItem(.separator())

        menu.addItem(action(isHidden() ? "Show Bar" : "Hide Bar", #selector(toggleHidden), key: "h"))
        menu.addItem(action("Reload Config", #selector(reload), key: "r"))
        let folder = action("Open Config Folder", #selector(openConfigFolder), key: ",")
        folder.toolTip = configDirectory().path
        menu.addItem(folder)

        menu.addItem(.separator())

        let login = action("Open at Login", #selector(toggleLoginItem))
        switch LoginItem.current {
        case .unavailable:
            login.isEnabled = false
            login.toolTip = "Available when bario runs from Bario.app."
        case .enabled:
            login.state = .on
        case .disabled:
            login.state = .off
        case .requiresApproval:
            // Registered, and the user turned it off. Neither on nor off would be the truth.
            login.state = .mixed
            login.toolTip = "Turned off in System Settings › General › Login Items."
        }
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("Quit bario", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: ObjectiveC.Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String, font: NSFont? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let font {
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: font])
        }
        return item
    }

    @objc private func toggleHidden() {
        onSetHidden?(!isHidden())
        refresh()
    }

    @objc private func reload() {
        onReload?()
    }

    /// Created if it is not there yet, so the first thing a new user sees is where the files go.
    @objc private func openConfigFolder() {
        let directory = configDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            warn("config folder: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.set(LoginItem.current != .enabled)
        } catch {
            warn("login item: \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Greedy word wrap, so an absolute path in an error cannot make the menu wider than the
    /// screen. A word longer than the width is left whole: a broken path cannot be pasted.
    static func wrap(_ text: String, at width: Int) -> [String] {
        var lines: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                if line.isEmpty {
                    line = String(word)
                } else if line.count + 1 + word.count <= width {
                    line += " " + word
                } else {
                    lines.append(line)
                    line = String(word)
                }
            }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

/// Whether bario starts at login. `SMAppService.mainApp` registers the containing bundle — no
/// LaunchAgent plist to write or clean up, and the switch shows in System Settings › General ›
/// Login Items, where the user can override it.
public enum LoginItem: Sendable {
    /// Not running from Bario.app: a bare `swift build` binary has nothing to register.
    case unavailable
    case enabled
    case disabled
    /// Registered, but switched off by the user. Only they can switch it back on.
    case requiresApproval

    /// Read when the menu opens, never cached: it can change in System Settings while bario runs.
    public static var current: LoginItem {
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    public static func set(_ wanted: Bool) throws {
        if wanted {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
