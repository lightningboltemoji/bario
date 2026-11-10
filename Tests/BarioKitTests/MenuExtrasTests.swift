import AppKit
import Testing
@testable import BarioKit

@Suite("The menu bar's other items")
struct MenuExtrasTests {
    func extra(_ app: String, bundle: String? = nil, pid: pid_t = 1, index: Int = 0, x: Double = 0,
               title: String? = nil, description: String? = nil, path: String? = nil) -> MenuExtra {
        MenuExtra(pid: pid, index: index, frame: CGRect(x: x, y: 7, width: 24, height: 24), title: title,
                  description: description, help: nil, bundleID: bundle, appName: app, appPath: path)
    }

    @Test("an app's item is its app, a title being no name; the system's say what they are")
    func names() {
        #expect(MenuExtras.name(of: extra("emira", bundle: "zip.tanner.emira", title: "1")) == "emira")
        #expect(MenuExtras.name(of: extra("MenuBarAgent", bundle: "com.apple.MenuBarAgent",
                                          description: "Wi‑Fi, connected, 3 bars")) == "Wi‑Fi")
        #expect(MenuExtras.name(of: extra("MenuBarAgent", bundle: "com.apple.MenuBarAgent",
                                          description: "Control Center")) == "Control Center")
        #expect(MenuExtras.name(of: extra("SystemUIServer", bundle: "com.apple.systemuiserver")) == "System")
    }

    @Test("a helper inside an app is that app")
    func outermostApp() {
        #expect(MenuExtras.outermostApp(
            "/System/Applications/Passwords.app/Contents/Library/LoginItems/PasswordsMenuBarExtra.app")
            == "/System/Applications/Passwords.app")
        #expect(MenuExtras.outermostApp("/Applications/Ghostty.app") == "/Applications/Ghostty.app")
        #expect(MenuExtras.outermostApp("/usr/local/bin") == nil)
    }

    @Test("items in the menu bar's order, with their picture, the app's icon, or a symbol")
    func patch() throws {
        let extras = [
            extra("Clock", pid: 3, x: 900, path: "/System/Library/CoreServices/MenuBarAgent.app"),
            extra("emira", pid: 2, index: 1, x: 100),
            extra("Passwords", pid: 4, x: 500, path: "/System/Applications/Passwords.app"),
        ]
        let icons = ["2:1": MenuExtras.Icon(path: "/tmp/a.png", kind: .template, width: 6)]
        let patch = MenuExtras.patch(extras, icons: icons)
        let items = try #require(patch["items"]?.arrayValue)
        #expect(items.map { $0["id"]?.stringValue } == ["2:1", "4:0", "3:0"])
        #expect(items[0]["icon"]?.stringValue == "/tmp/a.png")
        #expect(items[0]["kind"]?.stringValue == "template")
        #expect(items[1]["icon"]?.stringValue == "/System/Applications/Passwords.app")
        #expect(items[1]["kind"]?.stringValue == "app")
        #expect(patch["count"]?.doubleValue == 3)

        let bare = MenuExtras.patch([extra("bario")], icons: [:])
        #expect(bare["items"]?.arrayValue?.first?["kind"]?.stringValue == "symbol")
    }

    @Test("lines hold as many as fit, one at least, and never start empty")
    func lines() throws {
        // Each counts its width and the room around it in its cell.
        let widths = [20.0, 4, 16, 18, 17, 25.5, 13.5, 128]
        let extras = widths.indices.map { extra("app\($0)", pid: pid_t($0 + 1), x: Double($0) * 30) }
        let icons = Dictionary(uniqueKeysWithValues: extras.indices.map {
            (extras[$0].id, MenuExtras.Icon(path: "/tmp/\($0).png", kind: .template, width: widths[$0]))
        })
        func names(_ patch: JSONValue) -> [[String]] {
            (patch["lines"]?.arrayValue ?? []).map { ($0["items"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue } }
        }
        #expect(names(MenuExtras.patch(extras, icons: icons, lineWidth: 230)).map(\.count) == [7, 1])
        #expect(names(MenuExtras.patch(extras, icons: icons, lineWidth: 100)).map(\.count) == [3, 3, 1, 1])
        #expect(names(MenuExtras.patch(Array(extras.suffix(2)), icons: icons, lineWidth: 50))
                == [["app6"], ["app7"]], "wider than a line, alone on its own")
        #expect(names(MenuExtras.patch([], icons: [:])) == [])
    }

    @Test("hide leaves items out by name, app, bundle id or identifier, in any case")
    func hide() {
        var clock = extra("MenuBarAgent", bundle: "com.apple.MenuBarAgent", pid: 1, description: "Clock")
        clock.identifier = "com.apple.menuextra.clock"
        let emira = extra("emira", bundle: "zip.tanner.emira", pid: 2, title: "1")
        let passwords = extra("Passwords", bundle: "com.apple.Passwords.MenuBarExtra", pid: 3)
        let all = [clock, emira, passwords]
        func names(_ hidden: [String]) -> [String] { MenuExtras.visible(all, hiding: hidden).map(\.appName) }
        #expect(names([]) == ["MenuBarAgent", "emira", "Passwords"])
        #expect(names(["com.apple.menuextra.clock"]) == ["emira", "Passwords"])
        #expect(names(["clock", "PASSWORDS"]) == ["emira"])
        #expect(names(["zip.tanner.emira"]) == ["MenuBarAgent", "Passwords"])
        #expect(names(["1"]) == ["MenuBarAgent", "emira", "Passwords"], "a title is no name")

        #expect(MenuExtrasModule.strings(.string("a")) == ["a"])
        #expect(MenuExtrasModule.strings(.array([.string("a"), .array([.string("b"), .string("c")])]))
                == ["a", "b", "c"], "several hide lines, one with two")
        #expect(MenuExtrasModule.strings(nil) == [])
    }

    @Test("a row's id comes back as the item it names")
    func target() {
        #expect(MenuExtras.target("683:2").map { [Int($0.pid), $0.index] } == [683, 2])
        #expect(MenuExtras.target("683") == nil)
        #expect(MenuExtras.target("a:b") == nil)
    }

    /// A 2× picture of a 100×20pt bar at the origin, transparent but for the boxes given, in
    /// pixels, each filled with one colour.
    func picture(_ boxes: [(CGRect, (UInt8, UInt8, UInt8))]) -> MenuBarPicture {
        let width = 200, height = 40
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (box, colour) in boxes {
            for y in Int(box.minY)..<Int(box.maxY) {
                for x in Int(box.minX)..<Int(box.maxX) {
                    let i = (y * width + x) * 4
                    bytes[i] = colour.0; bytes[i + 1] = colour.1; bytes[i + 2] = colour.2; bytes[i + 3] = 255
                }
            }
        }
        return MenuBarPicture(width: width, height: height, bytes: bytes,
                              frame: CGRect(x: 0, y: 0, width: 100, height: 20), scale: 2)
    }

    @Test("every cut shares the band all items draw in, and is as wide as its own ink")
    func cuts() {
        // A tall glyph in the first item, a short one in the second, nothing in the third.
        let shot = picture([(CGRect(x: 10, y: 8, width: 12, height: 24), (0, 0, 0)),
                            (CGRect(x: 70, y: 16, width: 20, height: 8), (0, 0, 0))])
        let cuts = MenuExtraIcons.cuts(in: shot, frames: [
            "a": CGRect(x: 0, y: 0, width: 20, height: 20),
            "b": CGRect(x: 30, y: 0, width: 20, height: 20),
            "c": CGRect(x: 60, y: 0, width: 20, height: 20),
            "off": CGRect(x: 300, y: 0, width: 20, height: 20),
        ])
        #expect(cuts["a"] == CGRect(x: 10, y: 8, width: 12, height: 24))
        #expect(cuts["b"] == CGRect(x: 70, y: 8, width: 20, height: 24), "the band, not its own height")
        #expect(cuts["c"] == nil, "no ink, no picture")
        #expect(cuts["off"] == nil, "not on this menu bar")
    }

    @Test("a picture in one colour is a template; one with colours of its own is not")
    func template() {
        let shot = picture([(CGRect(x: 0, y: 0, width: 10, height: 10), (0, 0, 0)),
                            (CGRect(x: 20, y: 0, width: 10, height: 10), (255, 255, 255)),
                            (CGRect(x: 40, y: 0, width: 10, height: 10), (40, 120, 255))])
        #expect(MenuExtraIcons.isTemplate(CGRect(x: 0, y: 0, width: 10, height: 10), in: shot))
        #expect(MenuExtraIcons.isTemplate(CGRect(x: 20, y: 0, width: 10, height: 10), in: shot))
        #expect(!MenuExtraIcons.isTemplate(CGRect(x: 40, y: 0, width: 10, height: 10), in: shot))
    }

    @Test("the built-in menu is a grid of the pictures, each pressing its own item")
    func defaultMenu() async throws {
        let store = StateStore()
        let module = MenuExtrasModule(context: ModuleContext(item: "extras", store: store))
        await store.merge(MenuExtras.patch([extra("emira", pid: 7, title: "1")],
                                           icons: ["7:0": MenuExtras.Icon(path: "/tmp/e.png", kind: .template,
                                                                          width: 6)]),
                          at: "extras")
        let menu = try #require(try await module.menu(await store.reader(for: "extras")))
        // The lines are the menu's column, here of one.
        let line = try #require(menu.children.first)
        #expect(menu.children.count == 1)
        #expect(line.classes == ["extras"])
        let cell = try #require(line.children.first)
        #expect(cell.actions.click == "press '7:0'")
        #expect(cell.classes == ["extra"])
        guard case .icon(.file(let path))? = cell.children.first?.kind else {
            Issue.record("the cell is the picture")
            return
        }
        #expect(path == "/tmp/e.png")
        #expect(cell.children.first?.classes == ["extra-icon", "template"])

        await store.merge(MenuExtras.patch([], icons: [:]), at: "extras")
        #expect(try await module.menu(await store.reader(for: "extras")) == nil, "nothing to show, no menu")
    }
}

/// A menu that shows its state's `label`, which `menuWillOpen` brings up to date.
actor PreparingModule: Module {
    private(set) var menus = 0
    private(set) var opened = 0

    nonisolated var preparesMenu: Bool { true }

    func render(_ state: StateReader) async throws -> RenderResult { RenderResult(content: .text("a")) }

    func menuWillOpen() async -> JSONValue? {
        opened += 1
        return .object(["label": .string("fresh \(opened)")])
    }

    func menu(_ state: StateReader) async throws -> Node? {
        menus += 1
        return .column([.text(state.value("label")?.stringValue ?? "stale")])
    }
}

@Suite("A menu that reads fresh as it opens")
@MainActor
struct PreparedMenuTests {
    @Test("its first render waits for menuWillOpen, which is asked again at every opening")
    func waits() async throws {
        let module = PreparingModule()
        ModuleRegistry.registerBuiltIns()
        ModuleRegistry.register("preparing-test") { _ in module }
        let h = try Harness(#"item "a" module="preparing-test""#)
        var surfaces: [RecordingMenuSurface] = []
        h.loop.makeMenuSurface = { _ in
            let surface = RecordingMenuSurface()
            surfaces.append(surface)
            return surface
        }
        await h.start()
        h.loop.setBackdrop(MenuFrameTests.checker, for: 1)
        await h.settle()
        #expect(await module.opened == 0, "a closed menu asks nothing")

        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        #expect(surfaces.first?.label == "fresh 1")
        #expect(await module.menus == 1, "no render of what was there before")

        h.loop.closeMenu()
        await h.drain()
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        #expect(surfaces.last?.label == "fresh 2")
    }
}
