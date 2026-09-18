import Foundation

/// The version `make app` stamped into the enclosing bundle, from the git tag. `Bundle.main` for an
/// executable inside `Contents/MacOS` resolves to the bundle around it, so `--version`, the startup
/// banner and the `ping` reply all read one string — no codegen, and no way for them to disagree.
/// Run straight out of `.build` there is no bundle to read, which is exactly the case that is not a
/// release.
public let barioVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
