import Darwin
import Foundation

/// Instantaneous, stateless readings of *this* process's CPU and memory use,
/// straight from the Mach kernel — used by power/diagnostics surfaces to show how
/// hard local generation is working the machine. No timers or stored state: every
/// call answers "what is true right now"; the caller owns any cadence.
enum SystemResourceSampler {
    /// Total CPU across the process's live, non-idle threads, in percent. Can
    /// exceed 100 on multi-core (e.g. 230 ≈ 2.3 cores busy), which is exactly the
    /// signal we want while llama.cpp saturates the performance cores. Returns nil
    /// when the kernel won't hand over the thread list.
    static func cpuUsagePercent() -> Double? {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else {
            return nil
        }
        // `task_threads` allocates the array in our own address space and transfers
        // ownership; without this deallocate we'd leak a page on every sample.
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadList)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }

        let infoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var total = 0.0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info_data_t()
            var count = infoCount
            // `thread_info` writes into a C struct; rebind the typed pointer to the
            // `integer_t` array the Mach ABI expects, with a capacity matching the
            // count we pass so the kernel can't overrun the buffer.
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), rebound, &count)
                }
            }
            guard result == KERN_SUCCESS else { continue }
            // Idle threads report a stale cpu_usage from when they last ran; counting
            // them would pin the figure near 100% while the app is asleep. Skip them.
            if info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }

    /// Physical memory footprint in MB — the same `phys_footprint` Activity Monitor
    /// and Xcode's memory gauge report. Returns nil when `task_info` fails.
    static func memoryFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576.0
    }
}
