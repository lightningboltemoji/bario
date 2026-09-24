import Foundation

/// Static content from config: `item "hello" module="text" text="hi"`, or with a format
/// string over whatever else is in the store.
public actor TextModule: Module {
    private let context: ModuleContext
    private let template: FormatString?
    private let literal: String

    public init(context: ModuleContext) {
        self.context = context
        self.literal = context.string("text") ?? context.config["args"]?.arrayValue?.first?.stringValue ?? ""
        self.template = context.format.flatMap { try? FormatString.parse($0) }
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        if let content = context.content {
            return RenderResult(content: content)
        }
        if let template = context.template {
            return RenderResult(content: try template.render(state))
        }
        if let template {
            return RenderResult(content: template.render(state))
        }
        return RenderResult(content: literal.isEmpty ? nil : .text(literal))
    }
}

/// Renders whatever was pushed under its key, with no source of its own. This is what makes
/// `bario set ci '{"icon": "checkmark.circle", "status": "green"}'` work with no module at
/// all, and what a `content` push replaces wholesale. DESIGN.md §3.
public actor DataModule: Module {
    private let context: ModuleContext
    private let template: FormatString?
    private let hiddenUntilSet: Bool

    public init(context: ModuleContext) {
        self.context = context
        self.template = context.format.flatMap { try? FormatString.parse($0) }
        self.hiddenUntilSet = context.bool("hidden-until-set")
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        let own = state.own

        // A whole content tree pushed with `bario content <item>` wins over the config's own
        // content and over the format string.
        if let pushed = own["content"] {
            let node = try? JSONDecoder().decode(Node.self, from: pushed.encoded())
            return RenderResult(content: node,
                                classes: own["classes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                tooltip: own["tooltip"]?.stringValue,
                                visible: own["visible"]?.boolValue ?? true)
        }

        if let content = context.content {
            return RenderResult(content: content)
        }

        let isEmpty = own.objectValue?.isEmpty ?? true
        if isEmpty && hiddenUntilSet {
            return RenderResult(visible: false)
        }
        if let content = context.template {
            return RenderResult(content: try content.render(state),
                                classes: own["classes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                tooltip: own["tooltip"]?.stringValue)
        }
        guard let template else {
            return RenderResult(content: isEmpty ? nil : .text(own.stringValue ?? ""))
        }
        return RenderResult(content: template.render(state),
                            classes: own["classes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                            tooltip: own["tooltip"]?.stringValue)
    }
}

/// A timer aligned to the next second or minute, writing `now` into the store.
///
/// The alignment is the whole point: a clock that ticks half a second late looks broken. The
/// granularity comes from the format — a pattern with seconds in it ticks every second.
public actor ClockModule: Module {
    private let context: ModuleContext
    private let template: FormatString?
    private let datePattern: String
    private let timeZone: TimeZone
    private let locale: Locale

    public init(context: ModuleContext) {
        self.context = context
        let format = context.format ?? context.string("format") ?? "HH:mm"
        // The clock's format is a DateFormatter pattern unless it contains slots, because
        // `format="EEE d MMM  HH:mm"` is the shape everyone expects. Per-module, as documented.
        if format.contains("{") {
            self.template = try? FormatString.parse(format)
            self.datePattern = context.string("date-format") ?? "HH:mm"
        } else {
            self.template = nil
            self.datePattern = format
        }
        self.timeZone = context.string("timezone").flatMap(TimeZone.init(identifier:)) ?? .current
        self.locale = context.string("locale").map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    public func poll() async -> PollResult {
        let now = Date()
        return PollResult(patch: .object(["now": .number(now.timeIntervalSince1970)]),
                          every: ticksEverySecond ? 1 : 60)
    }

    private var ticksEverySecond: Bool {
        ClockModule.patternHasSeconds(datePattern)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        let now = state.value("now")?.asDate ?? Date()
        if let template {
            return RenderResult(content: template.render { path in
                path == "now" ? .string(self.string(for: now)) : state.value(path)
            })
        }
        return RenderResult(content: .text(string(for: now)))
    }

    private func string(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = datePattern
        return formatter.string(from: date)
    }

    /// A date pattern ticks every second if it shows seconds; quoted text does not count.
    static func patternHasSeconds(_ pattern: String) -> Bool {
        var inQuotes = false
        for c in pattern {
            if c == "'" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if c == "s" || c == "S" || c == "A" { return true }
        }
        return false
    }
}
