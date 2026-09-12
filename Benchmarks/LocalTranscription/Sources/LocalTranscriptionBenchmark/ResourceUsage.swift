import Darwin
import Foundation
import LocalTranscriptionBenchmarkKit

struct ProcessResourceSnapshot {
    let userCPUSeconds: Double
    let systemCPUSeconds: Double
    let peakResidentMemoryMB: Double

    static func capture() -> Self {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Self(
            userCPUSeconds: seconds(usage.ru_utime),
            systemCPUSeconds: seconds(usage.ru_stime),
            peakResidentMemoryMB: Double(usage.ru_maxrss) / 1_048_576
        )
    }

    func delta(from earlier: Self) -> Self {
        Self(
            userCPUSeconds: max(0, userCPUSeconds - earlier.userCPUSeconds),
            systemCPUSeconds: max(0, systemCPUSeconds - earlier.systemCPUSeconds),
            peakResidentMemoryMB: peakResidentMemoryMB
        )
    }

    private static func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}

enum HostProfiler {
    static func current() -> LocalTranscriptionBenchmarkHost {
        LocalTranscriptionBenchmarkHost(
            hardwareModel: sysctl("hw.model"),
            processor: sysctl("machdep.cpu.brand_string"),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    private static func architecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
