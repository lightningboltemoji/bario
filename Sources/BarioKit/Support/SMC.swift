import CBarioShim
import Darwin

/// The System Management Controller, read-only: reading it takes no privileges and no grant.
/// Its keys are undocumented and vary by machine, so any of them can come back nil.
enum SMC {
    /// One connection for the life of the process, however many items read through it.
    private static let connection = bario_smc_open()

    static func float(_ key: String) -> Float? {
        guard connection != MACH_PORT_NULL else { return nil }
        var value: Float = 0
        return bario_smc_read_float(connection, key, &value) == 1 ? value : nil
    }
}
