import Foundation
import Darwin

struct AppUsage: Identifiable {
    let id: String          // grouping key: .app bundle path, or executable path
    var name: String
    var appPath: String?    // outermost .app bundle, if any
    var memory: UInt64      // physical footprint, summed over the app's processes
    var cpu: Double         // % of one core, like Activity Monitor
    var power: Double       // watts (from the kernel's per-process energy counter)
    var disk: Double        // bytes/s read + written
    var processCount: Int
}

struct ProcessTops {
    var memory: [AppUsage] = []
    var cpu: [AppUsage] = []
    var power: [AppUsage] = []
    var disk: [AppUsage] = []
    var totalPower: Double = 0   // sum over all readable processes (your apps; system daemons need root)
}

/// Samples per-process memory, CPU, energy and disk I/O with libproc in one pass, grouping helpers
/// under their app. Only processes owned by the current user are readable without root.
final class ProcessSampler {
    private struct Counters { var cpu: UInt64; var energy: UInt64; var disk: UInt64 }
    private var pathCache: [pid_t: String] = [:]
    private var last: [pid_t: Counters] = [:]
    private var lastWall: UInt64 = 0

    func reset() {
        pathCache.removeAll()
        last.removeAll()
        lastWall = 0
    }

    func sample(top n: Int = 5) -> ProcessTops {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return ProcessTops() }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = lastWall == 0 ? 0 : Double(now - lastWall)      // ns
        let me = getpid()

        var groups: [String: AppUsage] = [:]
        var current: [pid_t: Counters] = [:]
        var alive: [pid_t: String] = [:]
        var totalPower = 0.0

        for i in 0..<min(count, pids.count) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var ri = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &ri) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard rc == 0 else { continue }
            let path = pathCache[pid] ?? Self.path(of: pid)
            alive[pid] = path
            let c = Counters(cpu: UInt64(Double(ri.ri_user_time &+ ri.ri_system_time) * SysInfo.timebase),
                             energy: ri.ri_energy_nj,
                             disk: ri.ri_diskio_bytesread &+ ri.ri_diskio_byteswritten)
            current[pid] = c

            let (key, name, appPath) = Self.group(path: path, pid: pid, me: me)
            var g = groups[key] ?? AppUsage(id: key, name: name, appPath: appPath, memory: 0, cpu: 0,
                                            power: 0, disk: 0, processCount: 0)
            g.memory &+= ri.ri_phys_footprint
            if wall > 0, let p = last[pid] {
                if c.cpu >= p.cpu { g.cpu += Double(c.cpu - p.cpu) / wall * 100 }
                if c.energy >= p.energy {
                    let w = Double(c.energy - p.energy) / wall     // nJ per ns = W
                    g.power += w
                    totalPower += w
                }
                if c.disk >= p.disk { g.disk += Double(c.disk - p.disk) / (wall / 1e9) }
            }
            g.processCount += 1
            groups[key] = g
        }
        pathCache = alive
        last = current
        lastWall = now

        let all = Array(groups.values)
        var tops = ProcessTops()
        tops.memory = Array(all.sorted { $0.memory > $1.memory }.prefix(n))
        if wall > 0 {
            tops.cpu = Array(all.filter { $0.cpu >= 0.05 }.sorted { $0.cpu > $1.cpu }.prefix(n))
            tops.power = Array(all.filter { $0.power >= 0.005 }.sorted { $0.power > $1.power }.prefix(n))
            tops.disk = Array(all.filter { $0.disk >= 1024 }.sorted { $0.disk > $1.disk }.prefix(n))
            tops.totalPower = totalPower
        }
        return tops
    }

    private static func path(of pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
        var nb = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nb, UInt32(nb.count))
        return String(cString: nb)
    }

    private static func group(path: String, pid: pid_t, me: pid_t) -> (key: String, name: String, appPath: String?) {
        if let r = path.range(of: ".app/") {
            let app = String(path[..<r.lowerBound]) + ".app"
            let name = (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return (app, name, app)
        }
        let exe = (path as NSString).lastPathComponent
        return (path.isEmpty ? "pid:\(pid)" : path, exe.isEmpty ? "pid \(pid)" : exe, nil)
    }
}
