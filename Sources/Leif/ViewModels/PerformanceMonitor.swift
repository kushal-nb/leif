import Foundation
import SwiftUI

/// Lightweight process-level performance monitor using Mach kernel APIs.
/// Samples every 2 seconds on a background thread — negligible overhead.
final class PerformanceMonitor: ObservableObject {
    @Published var memoryMB: Double = 0      // phys_footprint (same as Activity Monitor)
    @Published var residentMB: Double = 0    // resident_size (includes freed pages)
    @Published var cpuPercent: Double = 0
    @Published var peakMemoryMB: Double = 0

    private var timer: Timer?
    private var lastCPUInfo: (user: UInt64, system: UInt64, time: CFAbsoluteTime)?

    init() { start() }

    func start() {
        sample() // immediate first read
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func resetPeak() {
        peakMemoryMB = memoryMB
    }

    private func sample() {
        let (footprint, rss) = Self.memoryMetrics()
        let cpu = sampleCPU()
        DispatchQueue.main.async {
            self.memoryMB = footprint
            self.residentMB = rss
            self.cpuPercent = cpu
            if footprint > self.peakMemoryMB { self.peakMemoryMB = footprint }
        }
    }

    // MARK: - Memory via task_vm_info (phys_footprint)
    //
    // phys_footprint is the same metric Activity Monitor shows in the "Memory" column.
    // Unlike resident_size, it correctly accounts for:
    //   - Compressed pages (counted at compressed size)
    //   - Freed-but-still-mapped pages (NOT counted)
    //   - Purgeable/reusable pages (NOT counted)
    // This means it actually drops when memory is freed, unlike resident_size.

    /// Returns (phys_footprint, resident_size) in MB.
    /// phys_footprint = what Activity Monitor shows (actual usage).
    /// resident_size  = all mapped pages (includes freed-but-not-unmapped pages).
    private static func memoryMetrics() -> (footprint: Double, rss: Double) {
        // phys_footprint via task_vm_info
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr1 = withUnsafeMutablePointer(to: &vmInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &vmCount)
            }
        }
        let footprint = kr1 == KERN_SUCCESS ? Double(vmInfo.phys_footprint) / (1024 * 1024) : 0

        // resident_size via mach_task_basic_info
        var basicInfo = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr2 = withUnsafeMutablePointer(to: &basicInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &basicCount)
            }
        }
        let rss = kr2 == KERN_SUCCESS ? Double(basicInfo.resident_size) / (1024 * 1024) : 0

        return (footprint, rss)
    }

    // MARK: - CPU via task_thread_times_info

    private func sampleCPU() -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }

        let userUs = UInt64(info.user_time.seconds) * 1_000_000 + UInt64(info.user_time.microseconds)
        let sysUs  = UInt64(info.system_time.seconds) * 1_000_000 + UInt64(info.system_time.microseconds)
        let now    = CFAbsoluteTimeGetCurrent()

        defer { lastCPUInfo = (userUs, sysUs, now) }

        guard let last = lastCPUInfo else { return 0 }
        let elapsed = now - last.time
        guard elapsed > 0 else { return 0 }

        // Use signed arithmetic to avoid overflow when threads exit between samples
        let deltaUser = Int64(bitPattern: userUs) - Int64(bitPattern: last.user)
        let deltaSys  = Int64(bitPattern: sysUs)  - Int64(bitPattern: last.system)
        let totalDelta = deltaUser + deltaSys
        guard totalDelta > 0 else { return 0 }

        let deltaUs = Double(totalDelta)
        // Convert microseconds to seconds, then to percentage of wall time
        return min((deltaUs / 1_000_000) / elapsed * 100, 999)
    }
}
