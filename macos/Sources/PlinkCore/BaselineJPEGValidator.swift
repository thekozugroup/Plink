import Foundation

/// Checks entropy completeness without reconstructing pixels. ImageIO can conceal
/// a truncated scan even when it reports statusComplete and the file ends in EOI.
struct BaselineJPEGValidator {
    private struct Component {
        let horizontal: Int
        let vertical: Int
        let quantization: UInt8
    }

    private struct HuffmanTable {
        let counts: [Int]
        let symbols: [UInt8]
    }

    private let bytes: [UInt8]
    private var offset = 2
    private var components: [UInt8: Component] = [:]
    private var scanned: Set<UInt8> = []
    private var tables: [UInt8: HuffmanTable] = [:]
    private var quantizationTables: Set<UInt8> = []
    private var restartInterval = 0
    private var bitCount = 0
    private var bitByte = 0

    init(data: Data) {
        bytes = [UInt8](data)
    }

    mutating func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0,
              max(width, height) <= ScreenPreviewProtocol.maxLongEdge,
              min(width, height) <= ScreenPreviewProtocol.maxShortEdge,
              width <= ScreenPreviewProtocol.maxPixels / height,
              (10...ScreenPreviewProtocol.maxJPEGBytes).contains(bytes.count),
              bytes[0] == 0xff, bytes[1] == 0xd8
        else { throw PayloadPolicyError.malformedFrame }

        while offset < bytes.count {
            let marker = try readMarker()
            if marker == 0xd9 {
                guard !components.isEmpty, scanned.count == components.count,
                      offset == bytes.count else { throw PayloadPolicyError.malformedFrame }
                return
            }
            guard offset + 2 <= bytes.count else { throw PayloadPolicyError.malformedFrame }
            let length = word(at: offset)
            let start = offset + 2
            let end = offset + length
            guard length >= 2, end <= bytes.count else { throw PayloadPolicyError.malformedFrame }
            offset = end

            switch marker {
            case 0xc0:
                guard components.isEmpty, length >= 8, bytes[start] == 8,
                      word(at: start + 1) == height, word(at: start + 3) == width
                else { throw PayloadPolicyError.malformedFrame }
                let count = Int(bytes[start + 5])
                guard count > 0, length == 8 + 3 * count else { throw PayloadPolicyError.malformedFrame }
                for i in 0..<count {
                    let p = start + 6 + 3 * i
                    let id = bytes[p]
                    let h = Int(bytes[p + 1] >> 4)
                    let v = Int(bytes[p + 1] & 15)
                    guard components[id] == nil, (1...4).contains(h), (1...4).contains(v),
                          bytes[p + 2] <= 3 else { throw PayloadPolicyError.malformedFrame }
                    components[id] = Component(horizontal: h, vertical: v, quantization: bytes[p + 2])
                }
            case 0xc4:
                try readTables(start: start, end: end)
            case 0xdb:
                try readQuantization(start: start, end: end)
            case 0xdd:
                guard length == 4 else { throw PayloadPolicyError.malformedFrame }
                restartInterval = word(at: start)
            case 0xda:
                try readScan(start: start, end: end, width: width, height: height)
            case 0xe0...0xef, 0xfe:
                // Metadata is interpreted by ImageIO.
                break
            default:
                // Includes progressive, arithmetic, lossless, and stray restart markers.
                throw PayloadPolicyError.malformedFrame
            }
        }
        throw PayloadPolicyError.malformedFrame
    }

    private func word(at position: Int) -> Int {
        Int(bytes[position]) << 8 | Int(bytes[position + 1])
    }

    private mutating func readMarker() throws -> UInt8 {
        guard offset < bytes.count, bytes[offset] == 0xff else { throw PayloadPolicyError.malformedFrame }
        while offset < bytes.count && bytes[offset] == 0xff { offset += 1 }
        guard offset < bytes.count, bytes[offset] != 0 else { throw PayloadPolicyError.malformedFrame }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func readTables(start: Int, end: Int) throws {
        var p = start
        guard p < end else { throw PayloadPolicyError.malformedFrame }
        while p < end {
            guard p + 17 <= end else { throw PayloadPolicyError.malformedFrame }
            let id = bytes[p]
            guard id >> 4 <= 1, id & 15 <= 3 else { throw PayloadPolicyError.malformedFrame }
            let counts = bytes[(p + 1)..<(p + 17)].map(Int.init)
            let count = counts.reduce(0, +)
            p += 17
            guard count > 0, count <= 256, p + count <= end else { throw PayloadPolicyError.malformedFrame }
            // Canonical JPEG codes must leave the all-ones code unused. This also
            // prevents end-of-scan padding from supplying a missing block.
            var code = 0
            for (index, n) in counts.enumerated() {
                code += n
                guard code < (1 << (index + 1)) else { throw PayloadPolicyError.malformedFrame }
                code <<= 1
            }
            let symbols = Array(bytes[p..<(p + count)])
            for symbol in symbols {
                if id >> 4 == 0 {
                    guard symbol <= 11 else { throw PayloadPolicyError.malformedFrame }
                } else {
                    guard symbol == 0 || symbol == 0xf0 || (1...10).contains(Int(symbol & 15))
                    else { throw PayloadPolicyError.malformedFrame }
                }
            }
            tables[id] = HuffmanTable(counts: counts, symbols: symbols)
            p += count
        }
    }

    private mutating func readQuantization(start: Int, end: Int) throws {
        var p = start
        guard p < end else { throw PayloadPolicyError.malformedFrame }
        while p < end {
            let id = bytes[p]
            p += 1
            guard id <= 3, p + 64 <= end else { throw PayloadPolicyError.malformedFrame }
            for _ in 0..<64 {
                guard bytes[p] != 0 else { throw PayloadPolicyError.malformedFrame }
                p += 1
            }
            quantizationTables.insert(id)
        }
    }

    private mutating func readScan(start: Int, end: Int, width: Int, height: Int) throws {
        guard !components.isEmpty, start < end else { throw PayloadPolicyError.malformedFrame }
        let count = Int(bytes[start])
        guard (1...4).contains(count), end - start == 4 + 2 * count,
              bytes[end - 3] == 0, bytes[end - 2] == 63, bytes[end - 1] == 0
        else { throw PayloadPolicyError.malformedFrame }
        let maxH = components.values.map(\.horizontal).max()!
        let maxV = components.values.map(\.vertical).max()!
        var blocks: [(dc: HuffmanTable, ac: HuffmanTable)] = []
        var scanIDs: Set<UInt8> = []
        var columns = (width + 8 * maxH - 1) / (8 * maxH)
        var rows = (height + 8 * maxV - 1) / (8 * maxV)
        for i in 0..<count {
            let id = bytes[start + 1 + 2 * i]
            let selector = bytes[start + 2 + 2 * i]
            guard let component = components[id], !scanned.contains(id), scanIDs.insert(id).inserted,
                  quantizationTables.contains(component.quantization),
                  let dc = tables[selector >> 4], let ac = tables[0x10 | (selector & 15)]
            else { throw PayloadPolicyError.malformedFrame }
            if count == 1 {
                // Noninterleaved scans have one block per MCU, with no dummy edge blocks.
                columns = (width * component.horizontal + 8 * maxH - 1) / (8 * maxH)
                rows = (height * component.vertical + 8 * maxV - 1) / (8 * maxV)
            }
            let repetitions = count == 1 ? 1 : component.horizontal * component.vertical
            for _ in 0..<repetitions { blocks.append((dc, ac)) }
        }
        guard blocks.count <= 10 else { throw PayloadPolicyError.malformedFrame }
        var restart = 0
        for mcu in 0..<(columns * rows) {
            if restartInterval > 0, mcu > 0, mcu % restartInterval == 0 {
                try finishBits()
                guard try readMarker() == UInt8(0xd0 + restart) else { throw PayloadPolicyError.malformedFrame }
                restart = (restart + 1) % 8
            }
            for block in blocks {
                let dcSize = try symbol(using: block.dc)
                try skipBits(dcSize)
                var coefficient = 1
                while coefficient < 64 {
                    let ac = try symbol(using: block.ac)
                    if ac == 0 { break }
                    if ac == 0xf0 {
                        coefficient += 16
                        guard coefficient <= 64 else { throw PayloadPolicyError.malformedFrame }
                    } else {
                        coefficient += ac >> 4
                        guard coefficient < 64 else { throw PayloadPolicyError.malformedFrame }
                        try skipBits(ac & 15)
                        coefficient += 1
                    }
                }
            }
        }
        try finishBits()
        scanned.formUnion(scanIDs)
        // The outer parser must find a marker immediately after the final block.
        // It rejects extra entropy bytes, premature EOI, and trailing data.
    }

    private mutating func symbol(using table: HuffmanTable) throws -> Int {
        var code = 0
        var firstCode = 0
        var firstSymbol = 0
        for count in table.counts {
            code = (code << 1) | (try readBit())
            let index = code - firstCode
            if index >= 0, index < count { return Int(table.symbols[firstSymbol + index]) }
            firstSymbol += count
            firstCode = (firstCode + count) << 1
        }
        throw PayloadPolicyError.malformedFrame
    }

    private mutating func skipBits(_ count: Int) throws {
        for _ in 0..<count { _ = try readBit() }
    }

    private mutating func readBit() throws -> Int {
        if bitCount == 0 {
            guard offset < bytes.count else { throw PayloadPolicyError.malformedFrame }
            bitByte = Int(bytes[offset])
            offset += 1
            if bitByte == 0xff {
                // Never synthesize bits when encountering EOI or a restart marker.
                guard offset < bytes.count, bytes[offset] == 0 else { throw PayloadPolicyError.malformedFrame }
                offset += 1
            }
            bitCount = 8
        }
        bitCount -= 1
        return (bitByte >> bitCount) & 1
    }

    private mutating func finishBits() throws {
        let mask = (1 << bitCount) - 1
        guard bitByte & mask == mask else { throw PayloadPolicyError.malformedFrame }
        bitCount = 0
    }
}
