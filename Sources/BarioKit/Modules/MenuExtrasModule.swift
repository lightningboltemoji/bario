import Foundation

/// The other items in the menu bar, which the cover hides: every app's status item and the
/// system's own, each with its picture as the menu bar shows it, for a menu to show as a grid.
/// Choosing one presses the real item, whose own menu or window opens where macOS puts it.
///
/// Read when the menu opens and not otherwise (`preparesMenu`), plus once at start, so a
/// closed menu costs nothing.
///
/// State: `items`, in the menu bar's order, each with `id`, `name`, `app`, `bundle-id`,
/// `title`, `description`, `icon` (an image file or a symbol), `kind` (`template`, a picture
/// in one colour to draw as a mask; `colour`; `app`, the app's icon for an item with no picture;
/// `symbol`) and `width` (in the menu bar, in points); `lines`, the same items as lines of a
/// grid, each line's `items` as many as fit `line-width` points of the menu bar (230); and
/// `count`. Each item has its `identifier` too, where its app gives one. `hide` leaves items
/// out by name, app, bundle id or identifier: `hide "com.apple.menuextra.clock" "Passwords"`.
/// Verb: `press <id>`.
public actor MenuExtrasModule: Module {
    private let context: ModuleContext
    private let renderer: FormatRenderer
    private let directory: URL
    private let lineWidth: Double
    private let hidden: [String]
    private var warnedCapture = false

    public init(context: ModuleContext) {
        self.context = context
        renderer = FormatRenderer(context, format: "{icon}", fallback: "count")
        lineWidth = context.double("line-width", default: 230) ?? 230
        hidden = MenuExtrasModule.strings(context.config["hide"])
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bario/menu-extras/\(context.item)", isDirectory: true)
    }

    /// The menu bario shows for these when the config has none. Copy it into an item's
    /// `menu { … }` to change it, or to put it above something else.
    public static let defaultMenuKDL = """
    each "lines" {
      row class="extras" {
        each "items" {
          row class="extra" on-click="press {id}" { icon "{icon}" class="extra-icon {kind}" }
        }
      }
    }
    """

    private static let defaultMenu = MenuConfig.builtIn(defaultMenuKDL, for: "menu-extras")

    public func poll() async -> PollResult {
        PollResult(patch: await read(), nextIn: nil)
    }

    public nonisolated var preparesMenu: Bool { true }

    public func menuWillOpen() async -> JSONValue? {
        await read()
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: try renderer.render(state))
    }

    public func menu(_ state: StateReader) async throws -> Node? {
        guard (state.value("count")?.doubleValue ?? 0) > 0 else { return nil }
        return try MenuExtrasModule.defaultMenu?.render(state)
    }

    /// `press <id>`, from a row: off this actor, since the press is answered only once the
    /// item's menu closes.
    public func onEvent(_ event: ModuleEvent) async -> JSONValue? {
        guard event.name == MenuExtras.pressVerb,
              let id = event.payload["args"]?.arrayValue?.first?.stringValue,
              let target = MenuExtras.target(id) else { return nil }
        Task.detached {
            let result = MenuExtrasReader.press(pid: target.pid, index: target.index)
            if result != .success, result != .cannotComplete {
                warn("menu-extras: pressing \(id) failed (AXError \(result.rawValue))")
            }
        }
        return nil
    }

    /// The items and their pictures, now.
    private func read() async -> JSONValue {
        guard AppMenuReader.isTrusted(prompting: false) else {
            return MenuExtras.patch([], icons: [:], lineWidth: lineWidth)
        }
        let (apps, own) = await MainActor.run {
            let apps = MenuExtrasReader.runningApps()
            return (apps, MenuExtrasReader.ownItems(apps))
        }
        let extras = MenuExtras.visible(await Task.detached { MenuExtrasReader.read(apps) }.value + own,
                                        hiding: hidden)
        return MenuExtras.patch(extras, icons: await icons(for: extras), lineWidth: lineWidth)
    }

    /// Each item's picture, cut from the menu bar it is on and written where an icon can read
    /// it, under a name that changes with its pixels: an icon is measured and drawn once per path.
    private func icons(for extras: [MenuExtra]) async -> [String: MenuExtras.Icon] {
        let pictures: [MenuBarPicture]
        do {
            pictures = try await MenuExtrasReader.photograph()
        } catch {
            if !warnedCapture { warn("menu-extras: could not photograph the menu bar: \(error)") }
            warnedCapture = true
            return [:]
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var icons: [String: MenuExtras.Icon] = [:]
        for picture in pictures {
            let frames = Dictionary(extras.filter { picture.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
                .map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
            for (id, cut) in MenuExtraIcons.cuts(in: picture, frames: frames) {
                guard let png = MenuExtrasReader.png(cut, of: picture) else { continue }
                let kind: MenuExtras.Icon.Kind = MenuExtraIcons.isTemplate(cut, in: picture) ? .template : .colour
                let url = directory.appendingPathComponent("\(MenuExtrasModule.digest(png)).png")
                if !FileManager.default.fileExists(atPath: url.path) { try? png.write(to: url) }
                icons[id] = MenuExtras.Icon(path: url.path, kind: kind, width: cut.width / picture.scale)
            }
        }
        // What no item shows any more goes, a run before this one's included.
        let kept = Set(icons.values.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !kept.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
        return icons
    }

    /// `hide "a"`, `hide "a" "b"`, or several `hide` lines: every string in it.
    static func strings(_ value: JSONValue?) -> [String] {
        if let string = value?.stringValue { return [string] }
        return value?.arrayValue?.flatMap { strings($0) } ?? []
    }

    /// FNV-1a, 64 bits, as hex: a name for the bytes, the same in every run.
    static func digest(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
