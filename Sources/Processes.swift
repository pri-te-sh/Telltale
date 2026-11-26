import Foundation
import Darwin

struct AppUsage: Identifiable {
    let id: String          // grouping key: .app bundle path, or executable path
    var name: String
    var appPath: String?    // outermost .app bundle, if any
    var memory: UInt64      // physical footprint, summed over the app's processes
    var cpu: Double         // % of one core, like Activity Monitor
    var processCount: Int
}

/// Samples per-process memory and CPU with libproc and groups helpers under their app.
/// Only processes owned by the current user are readable without root, which is what we want.
final class ProcessSampler {
    private var pathCache: [pid_t: String] = [:]
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastWall: UInt64 = 0

    func reset() {
        pathCache.removeAll()
        lastCPU.removeAll()
        lastWall = 0
    }

    func sample(top n: Int = 5) -> (byMemory: [AppUsage], byCPU: [AppUsage]) {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return ([], []) }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = lastWall == 0 ? 0 : Double(now - lastWall)
        let me = getpid()

        var groups: [String: AppUsage] = [:]
        var cpuNow: [pid_t: UInt64] = [:]
        var alive: [pid_t: String] = [:]

        for i in 0..<min(count, pids.count) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var ri = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ri) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard rc == 0 else { continue }
            let path = pathCache[pid] ?? Self.path(of: pid)
            alive[pid] = path
            let t = UInt64(Double(ri.ri_user_time &+ ri.ri_system_time) * SysInfo.timebase)
            cpuNow[pid] = t

            let (key, name, appPath) = Self.group(path: path, pid: pid, me: me)
            var g = groups[key] ?? AppUsage(id: key, name: name, appPath: appPath, memory: 0, cpu: 0, processCount: 0)
            g.memory &+= ri.ri_phys_footprint
            if wall > 0, let prev = lastCPU[pid], t >= prev { g.cpu += Double(t - prev) / wall * 100 }
            g.processCount += 1
            groups[key] = g
        }
        pathCache = alive
        lastCPU = cpuNow
        lastWall = now

        let all = Array(groups.values)
        let byMem = all.sorted { $0.memory > $1.memory }.prefix(n)
        let byCPU = wall > 0 ? Array(all.filter { $0.cpu >= 0.05 }.sorted { $0.cpu > $1.cpu }.prefix(n)) : []
        return (Array(byMem), byCPU)
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
