package app.plink.android.transport

import org.junit.Assert.assertArrayEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream

class LengthPrefixedFrameCodecTest {
    @Test
    fun frameRoundTrips() {
        val output = ByteArrayOutputStream()
        val payload = "encrypted-frame".toByteArray()

        LengthPrefixedFrameCodec.write(DataOutputStream(output), payload)
        val decoded = LengthPrefixedFrameCodec.read(DataInputStream(ByteArrayInputStream(output.toByteArray())))

        assertArrayEquals(payload, decoded)
    }

    @Test(expected = IllegalArgumentException::class)
    fun emptyFrameFailsClosed() {
        val output = ByteArrayOutputStream()
        DataOutputStream(output).writeInt(0)

        LengthPrefixedFrameCodec.read(DataInputStream(ByteArrayInputStream(output.toByteArray())))
    }
}
