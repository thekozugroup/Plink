package app.plink.android.protocol

/** Validates complete baseline scans without allocating or reconstructing pixels. */
internal class BaselineJpegValidator(private val bytes: ByteArray) {
    private data class Component(val horizontal: Int, val vertical: Int, val quantization: Int)
    private data class Table(val counts: List<Int>, val symbols: List<Int>)
    private var offset = 2
    private val components = mutableMapOf<Int, Component>()
    private val scanned = mutableSetOf<Int>()
    private val tables = mutableMapOf<Int, Table>()
    private val quantizationTables = mutableSetOf<Int>()
    private var restartInterval = 0
    private var bitCount = 0
    private var bitByte = 0

    fun validate(width: Int, height: Int) {
        require(width > 0 && height > 0 &&
            maxOf(width, height) <= ScreenPreviewPayloadPolicy.maxLongEdge &&
            minOf(width, height) <= ScreenPreviewPayloadPolicy.maxShortEdge &&
            width <= ScreenPreviewPayloadPolicy.maxPixels / height &&
            bytes.size in 10..ScreenPreviewPayloadPolicy.maxJpegBytes &&
            byte(0) == 0xff && byte(1) == 0xd8)
        while (offset < bytes.size) {
            val marker = marker()
            if (marker == 0xd9) {
                require(components.isNotEmpty() && scanned.size == components.size && offset == bytes.size)
                return
            }
            require(offset + 2 <= bytes.size)
            val length = word(offset)
            val start = offset + 2
            val end = offset + length
            require(length >= 2 && end <= bytes.size)
            offset = end
            when (marker) {
                0xc0 -> {
                    require(components.isEmpty() && length >= 8 && byte(start) == 8 &&
                        word(start + 1) == height && word(start + 3) == width)
                    val count = byte(start + 5)
                    require(count in 1..4 && length == 8 + 3 * count)
                    repeat(count) { i ->
                        val p = start + 6 + 3 * i
                        val id = byte(p)
                        val h = byte(p + 1) shr 4
                        val v = byte(p + 1) and 15
                        require(id !in components && h in 1..4 && v in 1..4 && byte(p + 2) <= 3)
                        components[id] = Component(h, v, byte(p + 2))
                    }
                }
                0xc4 -> readTables(start, end)
                0xdb -> readQuantization(start, end)
                0xdd -> { require(length == 4); restartInterval = word(start) }
                0xda -> readScan(start, end, width, height)
                0xe1 -> validateExif(start, end)
                in 0xe0..0xef, 0xfe -> Unit
                else -> error("Unsupported JPEG marker.")
            }
        }
        error("Incomplete JPEG.")
    }

    private fun byte(position: Int): Int = bytes[position].toInt() and 0xff
    private fun word(position: Int): Int = (byte(position) shl 8) or byte(position + 1)

    private fun marker(): Int {
        require(offset < bytes.size && byte(offset) == 0xff)
        while (offset < bytes.size && byte(offset) == 0xff) offset++
        require(offset < bytes.size && byte(offset) != 0)
        return byte(offset++)
    }

    private fun readTables(start: Int, end: Int) {
        var p = start
        require(p < end)
        while (p < end) {
            require(p + 17 <= end)
            val id = byte(p)
            require(id shr 4 <= 1 && id and 15 <= 3)
            val counts = (p + 1 until p + 17).map(::byte)
            val count = counts.sum()
            p += 17
            require(count in 1..256 && p + count <= end)
            var code = 0
            counts.forEachIndexed { index, n ->
                code += n
                // All-ones codes are forbidden; padding cannot supply missing blocks.
                require(code < (1 shl (index + 1)))
                code = code shl 1
            }
            val symbols = (p until p + count).map(::byte)
            for (symbol in symbols) {
                require(if (id shr 4 == 0) symbol <= 11
                    else symbol == 0 || symbol == 0xf0 || symbol and 15 in 1..10)
            }
            tables[id] = Table(counts, symbols)
            p += count
        }
    }

    private fun readQuantization(start: Int, end: Int) {
        var p = start
        require(p < end)
        while (p < end) {
            val id = byte(p++)
            // Baseline sequential JPEG uses 8-bit, nonzero quantization entries.
            require(id in 0..3 && p + 64 <= end)
            repeat(64) { require(byte(p++) != 0) }
            quantizationTables += id
        }
    }

    private fun readScan(start: Int, end: Int, width: Int, height: Int) {
        require(components.isNotEmpty() && start < end)
        val count = byte(start)
        require(count in 1..4 && end - start == 4 + 2 * count &&
            byte(end - 3) == 0 && byte(end - 2) == 63 && byte(end - 1) == 0)
        val maxH = components.values.maxOf { it.horizontal }
        val maxV = components.values.maxOf { it.vertical }
        val blocks = mutableListOf<Pair<Table, Table>>()
        val scanIds = mutableSetOf<Int>()
        var columns = (width + 8 * maxH - 1) / (8 * maxH)
        var rows = (height + 8 * maxV - 1) / (8 * maxV)
        repeat(count) { i ->
            val id = byte(start + 1 + 2 * i)
            val selector = byte(start + 2 + 2 * i)
            val component = requireNotNull(components[id])
            require(component.quantization in quantizationTables)
            require(id !in scanned && scanIds.add(id))
            val dc = requireNotNull(tables[selector shr 4])
            val ac = requireNotNull(tables[0x10 or (selector and 15)])
            if (count == 1) {
                columns = (width * component.horizontal + 8 * maxH - 1) / (8 * maxH)
                rows = (height * component.vertical + 8 * maxV - 1) / (8 * maxV)
            }
            repeat(if (count == 1) 1 else component.horizontal * component.vertical) {
                blocks += dc to ac
            }
        }
        require(blocks.size <= 10)
        var restart = 0
        repeat(columns * rows) { mcu ->
            if (restartInterval > 0 && mcu > 0 && mcu % restartInterval == 0) {
                finishBits()
                require(marker() == 0xd0 + restart)
                restart = (restart + 1) % 8
            }
            for ((dc, ac) in blocks) {
                skipBits(symbol(dc))
                var coefficient = 1
                while (coefficient < 64) {
                    val value = symbol(ac)
                    if (value == 0) break
                    if (value == 0xf0) {
                        coefficient += 16
                        require(coefficient <= 64)
                    } else {
                        coefficient += value shr 4
                        require(coefficient < 64)
                        skipBits(value and 15)
                        coefficient++
                    }
                }
            }
        }
        finishBits()
        scanned += scanIds
    }

    private fun symbol(table: Table): Int {
        var code = 0
        var firstCode = 0
        var firstSymbol = 0
        for (count in table.counts) {
            code = (code shl 1) or readBit()
            val index = code - firstCode
            if (index in 0 until count) return table.symbols[firstSymbol + index]
            firstSymbol += count
            firstCode = (firstCode + count) shl 1
        }
        error("Invalid JPEG entropy code.")
    }

    private fun skipBits(count: Int) { repeat(count) { readBit() } }

    private fun readBit(): Int {
        if (bitCount == 0) {
            require(offset < bytes.size)
            bitByte = byte(offset++)
            if (bitByte == 0xff) {
                require(offset < bytes.size && byte(offset) == 0)
                offset++
            }
            bitCount = 8
        }
        bitCount--
        return (bitByte shr bitCount) and 1
    }

    private fun finishBits() {
        val mask = (1 shl bitCount) - 1
        require(bitByte and mask == mask)
        bitCount = 0
    }

    /** Only primary-image orientation applies; never follow thumbnail/GPS offsets. */
    private fun validateExif(start: Int, end: Int) {
        val signature = byteArrayOf(0x45, 0x78, 0x69, 0x66, 0, 0)
        if (end - start < 6 || signature.indices.any { bytes[start + it] != signature[it] }) return
        val base = start + 6
        require(end - base >= 8)
        val little = byte(base) == 0x49 && byte(base + 1) == 0x49
        require(little || byte(base) == 0x4d && byte(base + 1) == 0x4d)
        fun number(p: Int, size: Int): Long {
            require(p >= base && p <= end - size)
            var value = 0L
            repeat(size) { i ->
                value = value or (byte(p + i).toLong() shl (8 * if (little) i else size - i - 1))
            }
            return value
        }
        require(number(base + 2, 2) == 42L)
        val relative = number(base + 4, 4)
        require(relative in 8L..(end - base - 2).toLong())
        val ifd = base + relative.toInt()
        val count = number(ifd, 2).toInt()
        require(count <= (end - ifd - 2) / 12)
        var sawOrientation = false
        repeat(count) { i ->
            val p = ifd + 2 + 12 * i
            if (number(p, 2) == 0x112L) {
                require(!sawOrientation && number(p + 2, 2) == 3L &&
                    number(p + 4, 4) == 1L && number(p + 8, 2) == 1L)
                sawOrientation = true
            }
        }
    }
}
