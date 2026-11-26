import Foundation
import IOKit

struct FanInfo: Identifiable {
    let id: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var fraction: Double { maxRPM > 0 ? min(1, rpm / maxRPM) : 0 }
}

/// Read-only access to the System Management Controller (fan speeds). No root needed for reads.
/// The 80-byte SMCKeyData_t struct is handled as raw bytes at fixed C offsets to avoid Swift layout surprises.
final class SMC {
    private var conn: io_connect_t = 0

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        if IOServiceOpen(svc, mach_task_self_, 0, &conn) != KERN_SUCCESS { conn = 0 }
        IOObjectRelease(svc)
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    // Offsets inside SMCKeyData_t
    private let oKey = 0, oDataSize = 28, oDataType = 32, oResult = 40, oCommand = 42, oBytes = 48
    private let cmdReadKey: UInt8 = 5, cmdKeyInfo: UInt8 = 9

    private func call(_ input: [UInt8]) -> [UInt8]? {
        guard conn != 0 else { return nil }
        var i = input
        var o = [UInt8](repeating: 0, count: 80)
        var size = 80
        let r = IOConnectCallStructMethod(conn, 2, &i, 80, &o, &size)
        return r == KERN_SUCCESS && o[oResult] == 0 ? o : nil
    }

    private func write32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        withUnsafeBytes(of: v) { for k in 0..<4 { b[off + k] = $0[k] } }
    }

    private func read(_ key: String) -> (type: UInt32, bytes: [UInt8])? {
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var inp = [UInt8](repeating: 0, count: 80)
        write32(&inp, oKey, code)
        inp[oCommand] = cmdKeyInfo
        guard let info = call(inp) else { return nil }
        let size = info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: oDataSize, as: UInt32.self) }
        let type = info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: oDataType, as: UInt32.self) }
        guard size > 0, size <= 32 else { return nil }
        inp[oCommand] = cmdReadKey
        write32(&inp, oDataSize, size)
        guard let out = call(inp) else { return nil }
        return (type, Array(out[oBytes..<(oBytes + Int(size))]))
    }

    private func number(_ key: String) -> Double? {
        guard let (type, b) = read(key) else { return nil }
        switch type {
        case 0x666C7420 where b.count >= 4:   // "flt " (Apple Silicon, little-endian float)
            return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case 0x66706532 where b.count >= 2:   // "fpe2" (Intel, big-endian 14.2 fixed point)
            return Double((UInt16(b[0]) << 8) | UInt16(b[1])) / 4
        case 0x75693820:                      // "ui8 "
            return Double(b[0])
        case 0x75693136 where b.count >= 2:   // "ui16"
            return Double((UInt16(b[0]) << 8) | UInt16(b[1]))
        default:
            return nil
        }
    }

    func fans() -> [FanInfo] {
        guard let n = number("FNum"), n > 0 else { return [] }
        return (0..<min(Int(n), 4)).map { i in
            FanInfo(id: i, rpm: max(0, number("F\(i)Ac") ?? 0),
                    minRPM: number("F\(i)Mn") ?? 0, maxRPM: number("F\(i)Mx") ?? 0)
        }
    }
}
