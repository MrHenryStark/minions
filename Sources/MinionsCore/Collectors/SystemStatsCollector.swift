import Foundation
import Darwin

/// CPU / memory / disk without shelling out. CPU is a delta between two
/// samples, so the first call reports 0.
public final class SystemStatsCollector: @unchecked Sendable {
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private let lock = NSLock()
    public init() {}

    public func collect() -> SystemStats {
        var s = SystemStats()
        s.cpuPercent = cpu()
        (s.memoryUsedBytes, s.memoryTotalBytes) = memory()
        s.memoryPressure = pressure()
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            s.diskFreeBytes = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            s.diskTotalBytes = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
        }
        s.uptime = ProcessInfo.processInfo.systemUptime
        return s
    }

    private func cpu() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = (UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3))
        // order: user, system, idle, nice
        lock.lock(); defer { lock.unlock() }
        defer { lastTicks = (t.0, t.1, t.2, t.3) }
        guard let l = lastTicks else { return 0 }
        let user = t.0 - l.user, sys = t.1 - l.system, idle = t.2 - l.idle, nice = t.3 - l.nice
        let total = user + sys + idle + nice
        return total > 0 ? Double(user + sys + nice) / Double(total) * 100 : 0
    }

    private func memory() -> (UInt64, UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vm = vm_statistics64_data_t()
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        // "Memory used" as Activity Monitor shows it: app + wired + compressed.
        let used = (UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        return (used, total)
    }

    private func pressure() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            switch level { case 1: return "normal"; case 2: return "warn"; case 4: return "critical"; default: return "normal" }
        }
        return "normal"
    }
}
