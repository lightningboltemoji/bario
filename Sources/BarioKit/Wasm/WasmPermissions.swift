import Foundation

/// What a module's config granted it. A module that asks for nothing can do nothing but
/// compute, which is the point. DESIGN.md §5.
public struct WasmPermissions: Sendable, Equatable {
    public var net = false
    public var exec = false
    /// Path prefixes `read_file` may reach, already expanded and resolved.
    public var fs: [String] = []

    public init() {}

    public static func parse(_ config: JSONValue) throws -> WasmPermissions {
        var permissions = WasmPermissions()
        let granted: [String]
        switch config["permissions"] {
        case .some(.string(let one)): granted = [one]
        case .some(.array(let list)): granted = list.compactMap(\.stringValue)
        case .none: granted = []
        case .some(let other):
            throw ModuleError("permissions is a list of names, not \(other.jsonText.prefix(30))")
        }
        for name in granted {
            switch name {
            case "net": permissions.net = true
            case "exec": permissions.exec = true
            case "fs": break            // the paths are what grant it; see below
            default:
                throw ModuleError("'\(name)' is not a permission; they are net, exec and fs")
            }
        }
        switch config["fs"] {
        case .some(.string(let one)): permissions.fs = [one]
        case .some(.array(let list)): permissions.fs = list.compactMap(\.stringValue)
        default: break
        }
        permissions.fs = permissions.fs.map { WasmPermissions.canonical(($0 as NSString).expandingTildeInPath) }
        return permissions
    }

    /// Resolved after symlinks, so `~/.cache/weather` cannot become a route to `~/.ssh`.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public func allowsReading(_ path: String) -> Bool {
        guard !fs.isEmpty else { return false }
        let resolved = WasmPermissions.canonical((path as NSString).expandingTildeInPath)
        return fs.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
    }

    public var summary: String {
        var parts: [String] = []
        if net { parts.append("net") }
        if exec { parts.append("exec") }
        if !fs.isEmpty { parts.append("fs(\(fs.count))") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }
}
