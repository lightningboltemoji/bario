import AppKit

/// `bario --shot out.png`: build one bar offscreen, composite it, write it. No window, no menu
/// bar, no permissions — which is what makes the compositor testable and a visual regression a
/// diff of two files.
public enum Shot {
    @MainActor
    public static func run(options: RunOptions, theme: Theme) async throws -> CGImage {
        ModuleRegistry.registerBuiltIns()

        let width = options.shotWidth
        let height = options.shotHeight ?? 24
        var notch: CGRect?
        if let notchWidth = options.shotNotch, notchWidth > 0 {
            notch = CGRect(x: (width - notchWidth) / 2, y: 0, width: notchWidth, height: height)
        }
        let display = DisplayInfo(displayID: 1, name: "offscreen",
                                  frame: CGRect(x: 0, y: 0, width: width, height: 900),
                                  scale: CGFloat(options.shotScale), stripHeight: height,
                                  isBuiltIn: notch != nil,
                                  notch: notch.map { CGRect(x: $0.minX, y: 900 - height,
                                                            width: $0.width, height: height) })

        guard let bar = theme.config.bar(for: display) else {
            throw OptionError("no bar in the config matches a display called '\(display.name)'")
        }

        let scene = try await scene(bar: bar, display: display, theme: theme,
                                    dark: options.dark ?? false)

        let backdrop = BackdropImage()
        if let path = options.shotBackdrop {
            guard let image = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw OptionError("could not read the backdrop image at \(path)")
            }
            backdrop.set(cgImage)
        } else {
            backdrop.set(checkerboard(width: Int(width * options.shotScale),
                                      height: Int(height * options.shotScale)))
        }

        // `--window <gap>`: one full-width focused window that far below the bar, which is the
        // arrangement the shadow exists for. Bar coordinates, so the window is below zero.
        var shadows = ShadowField.empty
        if let gap = options.shotWindow {
            let window = CGRect(x: -40, y: -gap - 800, width: width + 80, height: 800)
            shadows = ShadowField(casters: [ShadowCaster(rect: window, shadow: .focused)])
        }

        guard let image = Offscreen.render(scene, backdrop: backdrop, shadows: shadows,
                                           resolver: ColorResolver.system(dark: options.dark ?? false),
                                           scale: CGFloat(options.shotScale))
        else { throw OptionError("could not render the bar") }
        return image
    }

    /// Build a scene with real modules: each gets its first poll, then renders once, as the
    /// first frame of a running bar would.
    @MainActor
    public static func scene(bar: BarConfig, display: DisplayInfo, theme: Theme,
                             dark: Bool, metrics: any Metrics = CoreTextMetrics()) async throws -> Scene {
        ModuleRegistry.registerBuiltIns()
        let host = ModuleHost()
        await host.load(bar.items)
        await host.renderPending()
        let states = host.states
        await host.shutdown()

        let cascade = Cascade(stylesheet: theme.stylesheet, dark: dark)
        let builder = SceneBuilder(cascade: cascade, metrics: metrics)
        return builder.build(bar: bar, display: display, items: bar.items, states: states)
    }

    /// A backdrop stand-in that makes transparency obvious in a screenshot.
    public static func checkerboard(width: Int, height: Int, square: Int = 8) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0.62, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0.52, alpha: 1))
        for y in stride(from: 0, to: height, by: square) {
            for x in stride(from: 0, to: width, by: square) where ((x / square) + (y / square)) % 2 == 0 {
                ctx.fill(CGRect(x: x, y: y, width: square, height: square))
            }
        }
        return ctx.makeImage()
    }

    /// `--diagnose`: the resolved scene as text, which is the fastest way to answer "why is
    /// that bubble there".
    public static func describe(_ scene: Scene) -> String {
        var lines: [String] = []
        lines.append(String(format: "bar %.0f×%.0f on %@%@", scene.bounds.width, scene.bounds.height,
                            scene.display.name, scene.notch != nil ? " (notched)" : ""))
        lines.append("  background: \(scene.style.background)  font: \(scene.style.font)")
        for (index, row) in scene.rows.enumerated() {
            lines.append(String(format: "  row %d  x %.0f…%.0f", index, row.frame.minX, row.frame.maxX))
            for item in row.items { describe(item, into: &lines, depth: 2) }
        }
        if !scene.hidden.isEmpty {
            lines.append("  overflowed: \(scene.hidden.map(\.name).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ item: SceneItem, into lines: inout [String], depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        let states = item.states.isEmpty ? "" : " :" + item.states.map(\.rawValue).sorted().joined(separator: ":")
        let classes = item.classes.isEmpty ? "" : " ." + item.classes.sorted().joined(separator: ".")
        lines.append(String(format: "%@%@ %@%@%@  x %.1f w %.1f h %.1f",
                            pad, item.typeName, item.name, classes, states,
                            item.frame.minX, item.frame.width, item.frame.height))
        for child in item.children { describe(child, into: &lines, depth: depth + 1) }
        if let content = item.content { describe(content, into: &lines, depth: depth + 1) }
    }

    private static func describe(_ node: SceneNode, into lines: inout [String], depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        var label = node.kind.typeName
        if case .text(let text) = node.kind { label += " \"\(text)\"" }
        if case .icon(let icon) = node.kind { label += " \(icon.name)" }
        let classes = node.classes.isEmpty ? "" : " ." + node.classes.joined(separator: ".")
        lines.append(String(format: "%@%@%@  x %.1f w %.1f h %.1f",
                            pad, label, classes, node.frame.minX, node.frame.width, node.frame.height))
        for child in node.children { describe(child, into: &lines, depth: depth + 1) }
    }
}
