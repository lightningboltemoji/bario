import AppKit

/// The socket verbs as a command line, one for one. DESIGN.md §4.
public enum CLI {
    public static let verbs = ["set", "content", "emit", "get", "watch", "style", "reload", "ping", "frame",
                               "palette"]

    public static let usage = """
    bario <verb> — talk to a running bar over its socket.

      bario set <target> [json]        merge state, e.g. bario set battery '{"pct": 43}'
      bario content <target> [json]    push a content tree to a `data` item
      bario emit <name> [json]         broadcast an event to modules and subscribers
      bario get [target]               print a subtree, or the whole store
      bario watch [topic…]             stream events until Ctrl-C (default '*')
      bario style [css]                apply a stylesheet delta live
      bario reload                     re-read the config and the stylesheet
      bario frame <surface> [index]    show a shared surface's other image, or the one at index
      bario palette [image…]           print each display's wallpaper palette, or each image's
      bario ping                       say whether a bar is running, and which

    A missing json or css argument is read from stdin, so `bario set ci < status.json` works.
    The socket is $TMPDIR/bario/sock, or $BARIO_SOCK.
    """

    public static func isVerb(_ word: String) -> Bool { verbs.contains(word) }

    /// Returns a process exit code.
    public static func run(_ arguments: [String]) -> Int32 {
        guard let verb = arguments.first else {
            note(usage)
            return 2
        }
        let rest = Array(arguments.dropFirst())
        // Measuring an image needs no bar.
        if verb == "palette", !rest.isEmpty { return MainActor.assumeIsolated { palette(files: rest) } }
        let client = SocketClient()
        do {
            try client.connect()
        } catch {
            warn("\(error)")
            return 1
        }
        defer { client.disconnect() }

        do {
            switch verb {
            case "ping":
                let reply = try client.send("ping")
                _ = reply
                // The useful part of a ping is on the reply object, not in `value`.
                note("bario is running")
                return 0

            case "set":
                guard let target = rest.first else { return usageError("set needs a target") }
                let data = try payload(rest.dropFirst().first, what: "set")
                try client.send("set", ["target": .string(target), "data": data])
                return 0

            case "content":
                guard let target = rest.first else { return usageError("content needs a target") }
                let tree = try payload(rest.dropFirst().first, what: "content")
                var fields: [String: JSONValue] = ["target": .string(target)]
                // Accept either a bare content tree or a whole render result.
                if tree["content"] != nil {
                    fields["content"] = tree["content"]
                    if let classes = tree["classes"] { fields["classes"] = classes }
                    if let tooltip = tree["tooltip"] { fields["tooltip"] = tooltip }
                } else {
                    fields["content"] = tree
                }
                try client.send("content", fields)
                return 0

            case "emit":
                guard let name = rest.first else { return usageError("emit needs an event name") }
                var fields: [String: JSONValue] = ["name": .string(name)]
                if let raw = rest.dropFirst().first {
                    fields["payload"] = try JSONValue(parsing: raw)
                }
                try client.send("emit", fields)
                return 0

            case "get":
                let target = rest.first ?? ""
                let value = try client.send("get", ["target": .string(target)]) ?? .null
                note(String(decoding: value.encoded(pretty: isatty(1) == 1, sortKeys: true),
                            as: UTF8.self))
                return 0

            case "style":
                let css = try text(rest.first, what: "style")
                try client.send("style", ["css": .string(css)])
                return 0

            case "reload":
                try client.send("reload")
                note("reloaded")
                return 0

            case "frame":
                guard let surface = rest.first else { return usageError("frame needs a surface name") }
                var fields: [String: JSONValue] = ["surface": .string(surface)]
                if let raw = rest.dropFirst().first {
                    guard let index = Int(raw) else { return usageError("frame's index is 0 or 1") }
                    fields["index"] = .number(Double(index))
                }
                try client.send("frame", fields)
                return 0

            case "palette":
                let value = try client.send("get", ["target": .string("wallpaper")]) ?? .null
                guard let displays = value["displays"]?.arrayValue, !displays.isEmpty else {
                    warn("the bar has no palette yet: it measures each display's wallpaper once it "
                         + "can photograph it or read its file")
                    return 1
                }
                note(displays.map { describePalette($0, title: $0["name"]?.stringValue ?? "display") }
                    .joined(separator: "\n\n"))
                return 0

            case "watch":
                let topics = rest.isEmpty ? ["*"] : rest
                try client.watch(topics) { event in
                    note(event.jsonText)
                    return true
                }
                return 0

            default:
                return usageError("unknown verb '\(verb)'")
            }
        } catch {
            warn("\(error)")
            return 1
        }
    }

    /// `bario palette <image…>`: each file measured as a wallpaper would be, at the palette's
    /// width, against the system's accent.
    @MainActor
    private static func palette(files: [String]) -> Int32 {
        let accent = RGBA(NSColor.controlAccentColor)
        var failed = false
        var reports: [String] = []
        for path in files {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let image = PaletteCapture.thumbnail(of: url) else {
                warn("could not read an image at \(path)")
                failed = true
                continue
            }
            let palette = Palette.extract(image, accent: accent)
            reports.append(describePalette(palette.json(display: path, id: 0, primary: false), title: path))
        }
        if !reports.isEmpty { note(reports.joined(separator: "\n\n")) }
        return failed ? 1 : 0
    }

    /// A palette as the store has it (PLAN.md W14), as text with truecolour swatches: the slots,
    /// the seeds and every cluster, with their numbers. `NO_COLOR` leaves the swatches out.
    static func describePalette(_ entry: JSONValue, title: String,
                                swatches: Bool = ProcessInfo.processInfo.environment["NO_COLOR"] == nil) -> String {
        func row(_ label: String, _ color: JSONValue?, _ note: String) -> String {
            let hex = color?["hex"]?.stringValue ?? "#000000"
            let lch = (color?["oklch"]?.arrayValue ?? []).compactMap(\.doubleValue)
            let oklch = lch.count == 3 ? String(format: "oklch(%.3f %.3f %5.1f)", lch[0], lch[1], lch[2]) : ""
            var swatch = ""
            if swatches, hex.count >= 7 {
                let digits = Array(hex.dropFirst())
                let channel = { (i: Int) in Int(String(digits[i * 2...i * 2 + 1]), radix: 16) ?? 0 }
                swatch = "\u{1B}[48;2;\(channel(0));\(channel(1));\(channel(2))m      \u{1B}[0m  "
            }
            let padded = label.padding(toLength: 15, withPad: " ", startingAt: 0)
            return "  \(padded)\(swatch)\(hex.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + "\(oklch)\(note.isEmpty ? "" : "  " + note)"
        }
        var lines = [title]
        let slots = entry["slots"]?.objectValue ?? [:]
        for name in Slot.Name.allCases.map(\.rawValue) {
            guard let slot = slots[name] else { continue }
            var note = slot["found"]?.boolValue == false ? "made up" : ""
            if let same = slot["same-as"]?.stringValue { note = "same as \(same)" }
            lines.append(row(name, slot, note))
        }
        let seeds = entry["seeds"]?.arrayValue ?? []
        if seeds.isEmpty { lines.append("  no seed: too little colour, so wallpaper(seed) is the accent") }
        for (index, seed) in seeds.enumerated() {
            let mass = seed["mass"]?.doubleValue.map { String(format: "mass %.3f", $0) } ?? ""
            lines.append(row("seed \(index + 1)", seed, mass))
        }
        lines.append("  clusters")
        for cluster in entry["clusters"]?.arrayValue ?? [] {
            let share = cluster["population"]?.doubleValue.map { String(format: "%5.1f%%", $0 * 100) } ?? ""
            lines.append(row("  " + share, cluster, ""))
        }
        return lines.joined(separator: "\n")
    }

    /// A JSON payload from the argument, or from stdin when it is missing.
    private static func payload(_ argument: String?, what: String) throws -> JSONValue {
        let raw = try text(argument, what: what)
        do {
            return try JSONValue(parsing: raw)
        } catch {
            throw SocketError("\(what) takes JSON, and '\(raw.prefix(40))' is not JSON")
        }
    }

    private static func text(_ argument: String?, what: String) throws -> String {
        if let argument { return argument }
        guard isatty(0) == 0 else {
            throw SocketError("\(what) needs an argument, or something on stdin")
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let raw = String(decoding: data, as: UTF8.self).trimmed
        guard !raw.isEmpty else { throw SocketError("\(what) read nothing from stdin") }
        return raw
    }

    private static func usageError(_ message: String) -> Int32 {
        warn(message)
        note(usage)
        return 2
    }
}
