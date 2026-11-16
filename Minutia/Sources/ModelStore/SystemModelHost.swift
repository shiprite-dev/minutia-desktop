import Foundation
import Network

final class SystemModelHost: ModelHost, @unchecked Sendable {
    private let monitor = NWPathMonitor()

    init() { monitor.start(queue: DispatchQueue(label: "app.minutia.desktop.model-network")) }

    deinit { monitor.cancel() }

    var isAppleSilicon: Bool { Self.sysctlInt("hw.optional.arm64") == 1 }
    var osVersion: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }
    var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }
    var osBuild: String { Self.sysctlString("kern.osversion") }

    func isNetworkExpensiveOrConstrained() -> Bool {
        let path = monitor.currentPath
        return path.isExpensive || path.isConstrained
    }

    func freeDiskBytes(at url: URL) -> Int64 {
        var existing = url
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            existing.deleteLastPathComponent()
        }
        let values = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private static func sysctlInt(_ name: String) -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname(name, &value, &size, nil, 0)
        return value
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
