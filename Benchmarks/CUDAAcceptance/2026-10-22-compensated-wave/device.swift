import Foundation
import Metal

func describe(_ device: MTLDevice) -> [String: Any] {
    ["name": device.name, "registryID": device.registryID, "unifiedMemory": device.hasUnifiedMemory]
}
let devices = MTLCopyAllDevices().map(describe)
let current = MTLCreateSystemDefaultDevice().map(describe)
let report: [String: Any] = [
    "devices": devices, "default": current as Any,
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "scope": "Contextual default/all-device query, not continuous per-process execution attestation",
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
