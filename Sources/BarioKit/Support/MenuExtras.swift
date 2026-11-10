import CoreGraphics
import Foundation

/// Another app's item in the menu bar (a status item, or a menu extra as Accessibility calls
/// it), as `MenuExtrasReader` found it. Pure, so what the menu shows is tested without AX.
struct MenuExtra: Sendable, Hashable {
    var pid: pid_t
    /// Its place among its app's items, which is how `press` finds it again.
    var index: Int
    /// Where it is in the menu bar, in global coordinates with the origin top left.
    var frame: CGRect
    var title: String?
    var description: String?
    var help: String?
    /// What Accessibility calls it, where the app says: the system's own have one each
    /// (`com.apple.menuextra.clock`), the same in every language.
    var identifier: String? = nil
    /// The app's bundle id. The system's own items share a host app, and are told apart by
    /// their description.
    var bundleID: String?
    /// The app as a person knows it: a helper inside an app is that app.
    var appName: String
    /// The app to draw when there is no picture of the item: the outermost `.app`.
    var appPath: String?

    /// `pid:index`, which `press` takes.
    var id: String { "\(pid):\(index)" }
}

enum MenuExtras {
    /// The verb a row presses its item with.
    static let pressVerb = "press"

    /// The apps that draw the system's own items, each several of them.
    static let systemHosts: Set<String> = ["com.apple.MenuBarAgent", "com.apple.systemuiserver",
                                          "com.apple.controlcenter"]

    /// What a row calls an item: its app's name, or for one of the system's own, what it says it
    /// is up to the first comma ("Wi‑Fi, connected, 3 bars" is Wi‑Fi). An app's title is no
    /// name: emira's is its workspace number.
    static func name(of extra: MenuExtra) -> String {
        guard let bundle = extra.bundleID, systemHosts.contains(bundle) else { return extra.appName }
        for text in [extra.description, extra.title, extra.help] {
            guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { continue }
            return text.components(separatedBy: ", ").first ?? text
        }
        return "System"
    }

    /// The outermost app in a bundle's path, without `.app`: Passwords for
    /// `/System/Applications/Passwords.app/Contents/Library/LoginItems/PasswordsMenuBarExtra.app`.
    static func outermostApp(_ path: String) -> String? {
        var url = URL(fileURLWithPath: "/")
        for component in URL(fileURLWithPath: path).pathComponents.dropFirst() {
            url.appendPathComponent(component)
            if component.hasSuffix(".app") { return url.path }
        }
        return nil
    }

    /// What one item looks like in the menu: its picture cut from the menu bar, or failing
    /// that its app's icon, or failing that a symbol.
    struct Icon: Sendable, Hashable {
        enum Kind: String, Sendable {
            /// A picture in one colour, drawn as a mask in the menu's.
            case template
            /// A picture with colours of its own.
            case colour
            /// The app's own icon, for an item with no picture.
            case app
            case symbol
        }

        var path: String
        var kind: Kind
        /// How wide it is in the menu bar, in points.
        var width: Double
    }

    /// How wide an app's icon or a symbol counts as, standing in for an item's picture.
    static let standInWidth = 18.0
    /// What a line counts for each item besides its picture: the room around it in its cell.
    static let cellRoom = 12.0

    /// The state the module writes: `items`, in the menu bar's order; the same in `lines`, each
    /// line's `items` as many as fit `lineWidth` points of the menu bar (one at least), for a
    /// grid; `count`; and the bubble's `icon`.
    static func patch(_ extras: [MenuExtra], icons: [String: Icon], lineWidth: Double = 230) -> JSONValue {
        var lines: [[JSONValue]] = []
        var used = 0.0
        let items = extras.sorted { $0.frame.minX < $1.frame.minX }.map { extra -> JSONValue in
            let icon = icons[extra.id] ?? extra.appPath.map { Icon(path: $0, kind: .app, width: standInWidth) }
                ?? Icon(path: "menubar.rectangle", kind: .symbol, width: standInWidth)
            func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
            let item = JSONValue.object([
                "id": .string(extra.id),
                "name": .string(name(of: extra)),
                "app": .string(extra.appName),
                "bundle-id": string(extra.bundleID),
                "title": string(extra.title),
                "description": string(extra.description),
                "identifier": string(extra.identifier),
                "icon": .string(icon.path),
                "kind": .string(icon.kind.rawValue),
                "width": .number(icon.width),
            ])
            let width = icon.width + cellRoom
            if lines.isEmpty || (used > 0 && used + width > lineWidth) {
                lines.append([])
                used = 0
            }
            lines[lines.count - 1].append(item)
            used += width
            return item
        }
        return .object(["items": .array(items),
                        "lines": .array(lines.map { .object(["items": .array($0)]) }),
                        "count": .number(Double(items.count)),
                        "icon": .string("menubar.rectangle")])
    }

    /// The items not left out by `hide`: by name, app, bundle id or identifier, in any case.
    static func visible(_ extras: [MenuExtra], hiding hidden: [String]) -> [MenuExtra] {
        let hidden = Set(hidden.map { $0.lowercased() })
        guard !hidden.isEmpty else { return extras }
        return extras.filter { extra in
            ![name(of: extra), extra.appName, extra.bundleID, extra.identifier]
                .contains { $0.map { hidden.contains($0.lowercased()) } ?? false }
        }
    }

    /// `pid:index`, back from a row.
    static func target(_ id: String) -> (pid: pid_t, index: Int)? {
        let parts = id.split(separator: ":")
        guard parts.count == 2, let pid = pid_t(parts[0]), let index = Int(parts[1]) else { return nil }
        return (pid, index)
    }
}

// MARK: - Cutting icons out of the menu bar

/// A photograph of a menu bar window, as premultiplied RGBA bytes, four to a pixel and no
/// padding, with the window's frame and how many pixels it has to the point.
struct MenuBarPicture: Sendable {
    var width: Int
    var height: Int
    var bytes: [UInt8]
    var frame: CGRect
    var scale: CGFloat

    func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

    /// Where an item is in the picture, in whole pixels, or nil if it is not on it.
    func pixels(of itemFrame: CGRect) -> CGRect? {
        let rect = CGRect(x: ((itemFrame.minX - frame.minX) * scale).rounded(),
                          y: ((itemFrame.minY - frame.minY) * scale).rounded(),
                          width: (itemFrame.width * scale).rounded(),
                          height: (itemFrame.height * scale).rounded())
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        return rect.isNull || rect.isEmpty ? nil : rect
    }
}

enum MenuExtraIcons {
    /// Less than this is the anti-aliasing at a glyph's edge, or nothing.
    static let ink: UInt8 = 12

    /// Where each item's picture is, by id: the band every item draws in, top to bottom, so the
    /// pictures keep their sizes relative to each other as they are scaled to one height, and
    /// from the item's first inked column to its last. An item with no ink has none.
    static func cuts(in picture: MenuBarPicture, frames: [String: CGRect]) -> [String: CGRect] {
        let areas = frames.compactMapValues { picture.pixels(of: $0) }
        var top = Int.max, bottom = Int.min
        for area in areas.values {
            for y in Int(area.minY)..<Int(area.maxY) {
                guard y < top || y > bottom else { continue }
                if (Int(area.minX)..<Int(area.maxX)).contains(where: { picture.alpha($0, y) >= ink }) {
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
            }
        }
        guard top <= bottom else { return [:] }
        var cuts: [String: CGRect] = [:]
        for (id, area) in areas {
            let columns = (Int(area.minX)..<Int(area.maxX)).filter { x in
                (top...bottom).contains { picture.alpha(x, $0) >= ink }
            }
            guard let left = columns.first, let right = columns.last else { continue }
            cuts[id] = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }
        return cuts
    }

    /// Whether a cut is in one colour, as an item drawn from a template image is (black over a
    /// light bar, white over a dark one), rather than in colours of its own.
    static func isTemplate(_ cut: CGRect, in picture: MenuBarPicture) -> Bool {
        var inked = 0, coloured = 0
        for y in Int(cut.minY)..<Int(cut.maxY) {
            for x in Int(cut.minX)..<Int(cut.maxX) {
                let i = (y * picture.width + x) * 4
                let a = Int(picture.bytes[i + 3])
                guard a >= 128 else { continue }
                inked += 1
                // Unpremultiplied, the spread between the channels is how far from grey it is.
                let r = Int(picture.bytes[i]) * 255 / a
                let g = Int(picture.bytes[i + 1]) * 255 / a
                let b = Int(picture.bytes[i + 2]) * 255 / a
                if max(r, g, b) - min(r, g, b) > 40 { coloured += 1 }
            }
        }
        return inked == 0 || coloured * 20 < inked
    }
}
