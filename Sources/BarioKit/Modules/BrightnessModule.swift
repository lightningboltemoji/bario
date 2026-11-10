import Foundation

/// The display's backlight and the keyboard's, for sliders in a menu. Polled, as
/// nothing announces the brightness keys or the ambient light sensor changing either; a change
/// bario makes is read back at once.
///
/// State: `display` and `keyboard` (0…1, or null where there is none), `display-pct` and
/// `keyboard-pct`, and `has-display` and `has-keyboard`. Verbs: `set-display` and
/// `set-keyboard` with a slider's `value`, or a percent as their argument.
public actor BrightnessModule: Module {
    private let context: ModuleContext
    private let renderer: FormatRenderer
    private let interval: Double

    public init(context: ModuleContext) {
        self.context = context
        renderer = FormatRenderer(context, format: "{icon}", fallback: "display-pct")
        if case .seconds(let seconds)? = context.interval { interval = seconds } else { interval = 2 }
    }

    /// The menu bario shows for brightness when the config has none. Copy it into an item's
    /// `menu { … }` to change it.
    public static let defaultMenuKDL = """
    if "has-display" {
      row class="header" { text "Display" }
      row { icon "sun.max.fill" class="glyph"; slider value="{display}" on-change="set-display" }
    }
    if "has-keyboard" {
      row class="header" { text "Keyboard" }
      row { icon "light.max" class="glyph"; slider value="{keyboard}" on-change="set-keyboard" }
    }
    separator
    row on-click="exec open 'x-apple.systempreferences:com.apple.Displays-Settings.extension'" { text "Displays Settings…" }
    """

    private static let defaultMenu = MenuConfig.builtIn(defaultMenuKDL, for: "brightness")

    public func poll() async -> PollResult {
        PollResult(patch: BrightnessModule.read(), every: interval)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: try renderer.render(state))
    }

    public func menu(_ state: StateReader) async throws -> Node? {
        try BrightnessModule.defaultMenu?.render(state)
    }

    public func onEvent(_ event: ModuleEvent) async -> JSONValue? {
        // A slider's `value` is 0…1; `set-display 40` is percent.
        let value = event.payload["value"]?.doubleValue
            ?? event.payload["args"]?.arrayValue?.first?.stringValue.flatMap(Double.init).map { $0 / 100 }
        switch event.name {
        case "set-display":
            guard let value, let display = Brightness.display() else { return nil }
            Brightness.set(value, of: display)
        case "set-keyboard":
            guard let value, let keyboard = Brightness.keyboard() else { return nil }
            Brightness.set(value, ofKeyboard: keyboard)
        default:
            return nil
        }
        return BrightnessModule.read()
    }

    static func read() -> JSONValue {
        let display = Brightness.display().flatMap(Brightness.level(of:))
        let keyboard = Brightness.keyboard().flatMap(Brightness.level(ofKeyboard:))
        func rounded(_ value: Double?) -> JSONValue { value.map { .number(($0 * 1000).rounded() / 1000) } ?? .null }
        func percent(_ value: Double?) -> JSONValue { value.map { .number(($0 * 100).rounded()) } ?? .null }
        return .object([
            "display": rounded(display),
            "keyboard": rounded(keyboard),
            "display-pct": percent(display),
            "keyboard-pct": percent(keyboard),
            "has-display": .bool(display != nil),
            "has-keyboard": .bool(keyboard != nil),
            "icon": .string(display.map { $0 < 0.5 ? "sun.min" : "sun.max" } ?? "sun.max.trianglebadge.exclamationmark"),
        ])
    }
}
