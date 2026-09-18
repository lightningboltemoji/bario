import AppKit
import BarioKit

programName = "bario"

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--version" {
    note(barioVersion)
    exit(0)
}
if arguments.isEmpty || arguments.first == "-h" || arguments.first == "--help" {
    note(RunOptions.usage)
    note("")
    note(CLI.usage)
    exit(0)
}

// One binary, two jobs: `--run` is the daemon, a verb is a client of it.
if let first = arguments.first, CLI.isVerb(first) {
    exit(CLI.run(arguments))
}

let options: RunOptions
do {
    options = try RunOptions.parse(arguments)
} catch {
    warn("\(error)")
    note(RunOptions.usage)
    exit(2)
}

// `--shot` and `--diagnose` are one-shot tools: a broken config there should fail loudly.
// `--run` starts anyway and shows the error on the bar, because that is where you can see it.
let theme: Theme
var startupError: String?
if options.shot != nil || options.diagnose {
    do {
        theme = try Theme.load(configPath: options.configPath, stylePath: options.stylePath)
    } catch {
        warn("\(error)")
        exit(1)
    }
} else {
    (theme, startupError) = Theme.loadOrDefault(configPath: options.configPath,
                                                stylePath: options.stylePath)
    if let startupError { warn(startupError) }
}

if let path = options.shot {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var status: Int32 = 0
    Task { @MainActor in
        do {
            let image = try await Shot.run(options: options, theme: theme)
            PNG.write(image, to: path)
            note("wrote \(path) (\(image.width)×\(image.height)px)")
        } catch {
            warn("\(error)")
            status = 1
        }
        semaphore.signal()
    }
    // A shot needs the main run loop for AppKit, but not an app.
    while semaphore.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    exit(status)
}

if options.diagnose {
    let semaphore = DispatchSemaphore(value: 0)
    Task { @MainActor in
        let screens = NSScreen.screens.compactMap { DisplayInfo(screen: $0) }
        let displays = screens.isEmpty
            ? [DisplayInfo(displayID: 1, name: "offscreen",
                           frame: CGRect(x: 0, y: 0, width: options.shotWidth, height: 900),
                           scale: 2, stripHeight: options.shotHeight ?? 24)]
            : screens
        for display in displays {
            guard let bar = theme.config.bar(for: display) else {
                warn("no bar matches \(display.name)")
                continue
            }
            if let scene = try? await Shot.scene(bar: bar, display: display, theme: theme,
                                                 dark: options.dark ?? false) {
                note(Shot.describe(scene))
            }
        }
        semaphore.signal()
    }
    while semaphore.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    exit(0)
}

if let other = SingleInstance.claim(name: "bario") {
    warn("already running\(other > 0 ? " as pid \(other)" : ""). Quit that one first, or `killall bario`.")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = BarController(options: options, theme: theme, startupError: startupError)
app.delegate = controller
app.run()
