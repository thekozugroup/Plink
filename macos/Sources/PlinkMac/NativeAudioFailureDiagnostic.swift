import Foundation
import Darwin
import MachO
import IOKit

/// Only image-relative system-framework locations leave this diagnostic.
struct NativeAudioFailureDiagnostic {
    private var consumed = false

    mutating func shouldCapture(owned: Bool, status: Int32?) -> Bool {
        guard owned, status == kIOReturnUnsupported, !consumed else { return false }
        consumed = true
        return true
    }

    struct Frame {
        let address: UInt
        let imageBase: UInt
    }

    struct Record: Equatable {
        let imageUUID: UUID?
        let offsets: [UInt]
        let transferInProgress: Bool

        var logLine: String {
            let state = imageUUID == nil ? "image_unavailable" : offsets.isEmpty ? "frames_unavailable" : "ready"
            let locations = offsets.map { String($0, radix: 16) }.joined(separator: ",")
            return "calls.audio.native_failure state=\(state) image_uuid=\(imageUUID?.uuidString ?? "unavailable") relative_pcs=\(locations) transfer_in_progress=\(transferInProgress)"
        }
    }

    static func normalized(imageUUID: UUID?, imageBase: UInt?, frames: [Frame], transferInProgress: Bool) -> Record {
        guard let imageUUID, let imageBase, imageBase != 0 else {
            return Record(imageUUID: nil, offsets: [], transferInProgress: transferInProgress)
        }
        let offsets = frames.prefix(64).lazy
            .filter { $0.imageBase == imageBase && $0.address >= imageBase }
            .prefix(8).map { $0.address - imageBase }
        return Record(imageUUID: imageUUID, offsets: Array(offsets), transferInProgress: transferInProgress)
    }

    static func capture(transferInProgress: Bool) -> Record {
        // Keep return addresses in memory only. No symbols, arguments or other images are logged.
        var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = addresses.withUnsafeMutableBufferPointer { backtrace($0.baseAddress!, Int32($0.count)) }
        guard let image = bluetoothImage() else {
            return normalized(imageUUID: nil, imageBase: nil, frames: [], transferInProgress: transferInProgress)
        }
        let frames = addresses.prefix(max(0, Int(count))).compactMap { address -> Frame? in
            guard let address else { return nil }
            var info = Dl_info()
            guard dladdr(address, &info) != 0, let base = info.dli_fbase else { return nil }
            return Frame(address: UInt(bitPattern: address), imageBase: UInt(bitPattern: base))
        }
        return normalized(imageUUID: image.uuid, imageBase: image.base, frames: frames, transferInProgress: transferInProgress)
    }

    private static func bluetoothImage() -> (uuid: UUID, base: UInt)? {
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index),
                  String(cString: name) == "/System/Library/Frameworks/IOBluetooth.framework/Versions/A/IOBluetooth",
                  let header = _dyld_get_image_header(index), header.pointee.magic == MH_MAGIC_64 else { continue }
            let raw = UnsafeRawPointer(header)
            let metadata = raw.load(as: mach_header_64.self)
            guard metadata.ncmds <= 4096, metadata.sizeofcmds <= 1_048_576 else { return nil }
            var offset = 0
            let commands = raw.advanced(by: MemoryLayout<mach_header_64>.size)
            let size = Int(metadata.sizeofcmds)
            for _ in 0..<metadata.ncmds {
                guard offset <= size - MemoryLayout<load_command>.size else { return nil }
                let command = commands.advanced(by: offset).load(as: load_command.self)
                let length = Int(command.cmdsize)
                guard length >= MemoryLayout<load_command>.size, length <= size - offset,
                      length.isMultiple(of: 8) else { return nil }
                if command.cmd == LC_UUID {
                    guard length >= MemoryLayout<uuid_command>.size else { return nil }
                    let uuid = commands.advanced(by: offset).load(as: uuid_command.self).uuid
                    return (UUID(uuid: uuid), UInt(bitPattern: raw))
                }
                offset += length
            }
            return nil
        }
        return nil
    }
}
