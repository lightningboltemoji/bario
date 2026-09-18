import Foundation

public struct RunOptions: Sendable {
    public var configPath: String?
    public var stylePath: String?
    public var source: SourceMode = .auto
    public var refresh: Double = 60
    public var duration: Double?
    public var debugTint = false
    public var dark: Bool?
    /// `--shot out.png`: render one bar offscreen and exit.
    public var shot: String?
    public var shotWidth: Double = 1440
    public var shotHeight: Double?
    public var shotNotch: Double?
    public var shotBackdrop: String?
    public var shotScale: Double = 2
    /// `--shot-window <gap>`: a focused window this many points below the bar, full width, so a
    /// shot shows the shadow the real thing would cast.
    public var shotWindow: Double?
    /// Cast the shadows of the windows behind the bar. On by default: without them the bar ends
    /// in a hard edge wherever a window is near the top of the screen.
    public var windowShadows = true
    public var diagnose = false
    public var traceFrames = false

    public init() {}

    public static let usage = """
    bario — a system bar for macOS, in the spirit of waybar.

    USAGE: bario --run [options]          run the bar
           bario --shot <path> [options]   render one bar to a PNG and exit
           bario <verb> [args]             talk to a running bar over its socket

    OPTIONS:
      --config <path>       config.kdl (default: ~/.config/bario/config.kdl)
      --style <path>        style.css  (default: ~/.config/bario/style.css)
      --source <mode>       auto | capture | wallpaper — where the backdrop comes from
      --refresh <sec>       how often to re-photograph the desktop, for wallpapers that
                            change on their own (default 60, 0 to disable)
      --dark / --light      force one appearance instead of following the system
      --duration <sec>      quit after N seconds
      --debug-tint          tint the cover so you can see exactly what it covers
      --no-window-shadows   do not cast the shadows of windows near the top of the screen
      --diagnose            print the resolved scene as text and exit
      --trace-frames        print a line for every frame: what was dirty, what was painted

    --shot options:
      --width <pt>          bar width (default 1440)
      --height <pt>         bar height (default: the menu bar height)
      --notch <pt>          pretend the display has a notch this wide, centred
      --backdrop <path>     an image to use as the photographed backdrop
      --scale <n>           points per pixel (default 2)
      --window <gap>        cast the shadow of a focused window this many points below the bar

    Quit with Ctrl-C, or `killall bario`.
    """

    public static func parse(_ args: [String]) throws -> RunOptions {
        var o = RunOptions()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw OptionError("\(flag) needs a value") }
            return args[i]
        }
        func number(_ flag: String) throws -> Double {
            let raw = try value(flag)
            guard let n = Double(raw) else { throw OptionError("\(flag) needs a number, got '\(raw)'") }
            return n
        }
        while i < args.count {
            switch args[i] {
            case "--run": break
            case "--config": o.configPath = try value("--config")
            case "--style": o.stylePath = try value("--style")
            case "--refresh": o.refresh = try max(0, number("--refresh"))
            case "--duration": o.duration = try number("--duration")
            case "--debug-tint": o.debugTint = true
            case "--no-window-shadows": o.windowShadows = false
            case "--window": o.shotWindow = try number("--window")
            case "--dark": o.dark = true
            case "--light": o.dark = false
            case "--diagnose": o.diagnose = true
            case "--trace-frames": o.traceFrames = true
            case "--shot": o.shot = try value("--shot")
            case "--width": o.shotWidth = try number("--width")
            case "--height": o.shotHeight = try number("--height")
            case "--notch": o.shotNotch = try number("--notch")
            case "--backdrop": o.shotBackdrop = try value("--backdrop")
            case "--scale": o.shotScale = try number("--scale")
            case "--source":
                let raw = try value("--source")
                guard let mode = SourceMode(rawValue: raw) else {
                    throw OptionError("--source must be auto, capture or wallpaper, got '\(raw)'")
                }
                o.source = mode
            default:
                throw OptionError("unknown option '\(args[i])'")
            }
            i += 1
        }
        return o
    }
}

public struct OptionError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Config and stylesheet, loaded together, with bario's own defaults underneath the user's.
public struct Theme: Sendable {
    public var config: Config
    public var stylesheet: Stylesheet
    public var configURL: URL?
    public var styleURL: URL?

    /// What the daemon starts with: the user's theme, or the built-in one carrying the reason
    /// it could not use theirs. A bar that refuses to start is a bar you cannot see the error
    /// message on, and the watcher will pick up the fix a moment later anyway.
    public static func loadOrDefault(configPath: String? = nil, stylePath: String? = nil)
        -> (theme: Theme, error: String?) {
        do {
            return (try load(configPath: configPath, stylePath: stylePath), nil)
        } catch {
            let fallback = Theme(config: (try? ConfigLoader.parse(defaultConfigKDL)) ?? Config(),
                                 stylesheet: (try? Stylesheet.parse(defaultStyleCSS)) ?? Stylesheet())
            return (fallback, "\(error)")
        }
    }

    public static func load(configPath: String? = nil, stylePath: String? = nil) throws -> Theme {
        let configURL = configPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? ConfigLoader.locate("config.kdl")
        let config: Config
        if let configURL {
            config = try ConfigLoader.parse(String(contentsOf: configURL, encoding: .utf8),
                                            source: configURL.path)
        } else {
            config = try ConfigLoader.parse(defaultConfigKDL, source: "<default config>")
        }

        // The built-in stylesheet is always underneath, so a user's file only has to say what
        // it wants to change.
        var stylesheet = try Stylesheet.parse(defaultStyleCSS, source: "<default style>")
        let styleURL = stylePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? ConfigLoader.locate("style.css")
        if let styleURL {
            stylesheet = stylesheet.appending(
                try Stylesheet.parse(String(contentsOf: styleURL, encoding: .utf8), source: styleURL.path))
        }
        return Theme(config: config, stylesheet: stylesheet, configURL: configURL, styleURL: styleURL)
    }
}
