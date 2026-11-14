package com.ias.specula

import java.io.*
import java.math.BigInteger
import org.junit.Assert.*
import org.junit.Test

internal fun hex(s: String) = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

class ProtocolTest {
    @Test
    fun desKnownVectorAndValidation() {
        assertArrayEquals(
            hex("8ca64de9c1b123a78ca64de9c1b123a7"),
            Wire.challenge(ByteArray(16), "\u0000"),
        )
        for (pass in listOf("", "123456789", "한글")) assertThrows(IOException::class.java) {
            Wire.challenge(ByteArray(16), pass)
        }
        assertThrows(IOException::class.java) { Wire.challenge(ByteArray(15), "test") }
    }

    @Test
    fun wirePacketsAndPixelFormat() {
        assertArrayEquals(hex("040100000000ffeb"), Wire.key(0xffeb, true))
        assertArrayEquals(hex("040000000000ffeb"), Wire.key(0xffeb, false))
        assertArrayEquals(hex("050107800438"), Wire.pointer(1920, 1080, 1))
        assertArrayEquals(hex("0504000a0014"), Wire.pointer(10, 20, 4))
        assertArrayEquals(hex("02000005000000100000000100000000ffffff21ffffff20"), Wire.encodings)
        assertArrayEquals(hex("2018000100ff00ff00ff000810000000"), Wire.format)
    }

    @Test
    fun credentialsTerminatedWithoutTruncation() {
        val block = ARD.credentials("alex", "암호", ByteArray(128) { 0xaa.toByte() })
        assertArrayEquals(byteArrayOf(97, 108, 101, 120, 0), block.copyOf(5))
        assertEquals(0, block[70].toInt())
        assertEquals(0xaa, block[127].toInt() and 255)
        for (name in listOf("", "a\u0000b", "a".repeat(64))) assertThrows(IOException::class.java) {
            ARD.credentials(name, "secret", ByteArray(128))
        }
        assertThrows(IOException::class.java) {
            ARD.credentials("alex", "한".repeat(22), ByteArray(128))
        }
        assertArrayEquals(byteArrayOf(0, 0, 1, 0), ARD.padded(BigInteger.valueOf(256), 4))
    }

    @Test
    fun solidRawPackedAndRuns() {
        ZRLE().use { z ->
            assertArrayEquals(hex("0000ffff0000ffff"), z.decode(2, 1, hex("010000ff")))
            assertArrayEquals(hex("ff0000ff00ff00ff"), z.decode(2, 1, hex("00ff000000ff00")))
            val packed = z.decode(3, 2, hex("02000000ffffffa040"))
            assertArrayEquals(hex("ffffffff000000ffffffffff000000ffffffffff000000ff"), packed)
            assertArrayEquals(
                hex("ff0000ffff0000ffff0000ff00ff00ff"),
                z.decode(4, 1, hex("80ff00000200ff0000")),
            )
            assertArrayEquals(
                hex("000000ffffffffffffffffffffffffff"),
                z.decode(4, 1, hex("82000000ffffff008102")),
            )
        }
    }

    @Test
    fun paletteReuseAcrossTilesAndRectangles() {
        ZRLE().use { z ->
            val data = hex("02000000ffffff") + ByteArray(8) + hex("7f80")
            val frame = z.decode(65, 1, data)
            assertArrayEquals(hex("000000ff"), frame.copyOf(4))
            assertArrayEquals(hex("ffffffff"), frame.takeLast(4).toByteArray())
            z.decode(64, 1, hex("82000000ffffff813f"))
            assertArrayEquals(hex("000000ff"), z.decode(1, 1, hex("8100")))
        }
        ZRLE().use { z -> assertThrows(IOException::class.java) { z.decode(1, 1, hex("7f00")) } }
    }

    @Test
    fun syncFlushedStreamStaysPersistent() {
        ZRLE().use { z ->
            assertEquals(
                "hello",
                z.inflate(hex("789cca48cdc9c907000000ffff"), 100).toString(Charsets.UTF_8),
            )
            assertEquals(
                "world!!",
                z.inflate(hex("2acf2fca49515404000000ffff"), 100).toString(Charsets.UTF_8),
            )
        }
        ZRLE().use { z ->
            val a = z.compressed(64, 64, hex("78da62e4e46007000000ffff"))
            val b = z.compressed(64, 64, hex("62046200000000ffff"))
            assertArrayEquals(a, b)
            assertArrayEquals(hex("090807ff"), a.copyOf(4))
        }
    }

    @Test
    fun fourKAndSixKLimitsAndDecode() {
        assertTrue(FrameLimits.valid(6016, 3384))
        assertFalse(FrameLimits.valid(8192, 8192))
        assertTrue(FrameLimits.compressed(3840, 2160) > 8000000)
        assertTrue(FrameLimits.compressed(64, 64) < 9000000)
        ZRLE().use { z ->
            val frame =
                z.compressed(
                    3840,
                    2160,
                    hex(
                        "78daedc3a10d00000803b0cca2d1fbff4cde40b44933dba8aaaaaaaaaaaaaaaf1f74ece628"
                    ),
                )
            assertEquals(3840 * 2160 * 4, frame.size)
            assertArrayEquals(hex("0a141eff"), frame.copyOf(4))
            assertArrayEquals(hex("0a141eff"), frame.takeLast(4).toByteArray())
        }
    }

    @Test
    fun malformedInputAndInflateBombsAreRejected() {
        for (bytes in listOf("11", "03000000ffffff010203c0", "8000000001", "0100000000", "7f00")) {
            ZRLE().use { z -> assertThrows(IOException::class.java) { z.decode(1, 1, hex(bytes)) } }
        }
        ZRLE().use { z ->
            assertThrows(IOException::class.java) {
                z.inflate(hex("789cca48cdc9c907000000ffff"), 4)
            }
        }
    }

    @Test
    fun overlappingCopyRectUsesOriginalPixelsAndResize() {
        val c = RfbClient()
        c.initReplay(4, 1)
        fun update(body: ByteArray) = DataInputStream(ByteArrayInputStream(body))
        ZRLE().use { z ->
            c.readUpdate(
                update(
                    Wire.packet {
                        writeByte(0)
                        writeShort(1)
                        writeShort(0)
                        writeShort(0)
                        writeShort(4)
                        writeShort(1)
                        writeInt(0)
                        write(hex("01000000020000000300000004000000"))
                    }
                ),
                z,
            )
            c.readUpdate(
                update(
                    Wire.packet {
                        writeByte(0)
                        writeShort(1)
                        writeShort(1)
                        writeShort(0)
                        writeShort(3)
                        writeShort(1)
                        writeInt(1)
                        writeShort(0)
                        writeShort(0)
                    }
                ),
                z,
            )
            assertArrayEquals(hex("010000ff010000ff020000ff030000ff"), c.frame().rgba)
            c.readUpdate(
                update(
                    Wire.packet {
                        writeByte(0)
                        writeShort(1)
                        writeShort(0)
                        writeShort(0)
                        writeShort(1)
                        writeShort(4)
                        writeInt(-223)
                    }
                ),
                z,
            )
            assertEquals(1, c.width)
            assertEquals(4, c.height)
        }
    }

    @Test
    fun physicalKeysPreserveMacCommandOptionAndLatinPositions() {
        assertEquals(0xffeb, PhysicalKey.symbol(226))
        assertEquals(0xffe7, PhysicalKey.symbol(230))
        assertEquals(0xffeb, PhysicalKey.symbol(227))
        assertEquals(0x0100201c, PhysicalKey.symbol(47, option = true))
        assertEquals(0x01002018, PhysicalKey.symbol(48, option = true))
        assertEquals(0x0100201d, PhysicalKey.symbol(47, shift = true, option = true))
        assertEquals(0x01002019, PhysicalKey.symbol(48, shift = true, option = true))
        assertEquals(91, PhysicalKey.symbol(47))
        assertEquals(93, PhysicalKey.symbol(48))
        assertEquals(0xff51, PhysicalKey.symbol(80, option = true))
        assertEquals(0x72, PhysicalKey.symbol(21))
        assertEquals(0x52, PhysicalKey.symbol(21, shift = true))
        assertEquals(0x21, PhysicalKey.symbol(30, shift = true))
        assertNull(PhysicalKey.symbol(999))
    }

    @Test
    fun compressedFixturesAndRepeatedFrameThroughput() {
        ZRLE().use { z ->
            val image = z.compressed(65, 1, hex("789c62626060f8ffff3f0314d43700000000ffff"))
            assertArrayEquals(hex("000000ff"), image.copyOf(4))
            assertArrayEquals(hex("ffffffff"), image.takeLast(4).toByteArray())
        }
        var produced = 0
        val start = System.nanoTime()
        repeat(40) {
            ZRLE().use { z ->
                produced +=
                    z.inflate(
                            hex(
                                "789cedc13101000000c2a0f54f6d0d0fa00000000000000000000000000000000000000078304e200001"
                            ),
                            20000,
                        )
                        .size
            }
        }
        assertEquals(800000, produced)
        assertTrue((System.nanoTime() - start) / 1000000000.0 < 2)
    }

    @Test
    fun inflaterHandlesSeventeenByteFragments() {
        val bytes =
            java.util.Base64.getDecoder()
                .decode(
                    "eJxjYGRiZmFlY+fg5OLm4eXjFxAUEhYRFROXkJSSlpGVk1dQVFJWUVVT19DU0tbR1dM3MDQyNjE1M7ewtLK2sbWzd3B0cnZxdXP38PTy9vH18w8IDAoOCQ0Lj4iMio6JjYtPSExKTklNS8/IzMrOyc3LLygsKi4pLSuvqKyqrqmtq29obGpuaW1r7+js6u7p7eufMHHS5ClTp02fMXPW7Dlz581fsHDR4iVLly1fsXLV6jVr163fsHHT5i1bt23fsXPX7j179+0/cPDQ4SNHjx0/cfLU6TNnz52/cPHS5StXr12/cfPW7Tt3791/8PDR4ydPnz1/8fLV6zdv373/8PHT5y9fv33/8fMXw6jXR70+6vVRr496fdTro14f9fqo10e9Pur1Ua+Pen3U66NeH/X6qNdHvT7q9VGvj3p91OujXh/1+qjXR70+6vVRr496fdTrMK8DACxSNXI="
                )
        val out = ByteArrayOutputStream()
        ZRLE().use { z ->
            bytes.asList().chunked(17).forEach { out.write(z.inflate(it.toByteArray(), 8000)) }
        }
        assertArrayEquals(ByteArray(8000) { (it % 251).toByte() }, out.toByteArray())
    }

    @Test
    fun realScreenSharingCaptureWithWifiSizedReads() {
        val fixture =
            javaClass.getResourceAsStream("/Fixtures/screen-sharing-zrle.bin")!!.readBytes()
        assertEquals(1791118, fixture.size)
        var reads = 0
        val fragmented =
            object : FilterInputStream(ByteArrayInputStream(fixture)) {
                val random = java.util.Random(0x5A17C0DE)

                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    reads++
                    return super.read(b, off, minOf(len, 1 + random.nextInt(1500)))
                }
            }
        val input = DataInputStream(fragmented)
        val client = RfbClient()
        client.initReplay(1600, 1200)
        var frames = 0
        ZRLE().use { z ->
            while (input.available() > 0) {
                assertEquals(0, input.readUnsignedByte())
                if (client.readUpdate(input, z)) frames++
            }
        }
        var hash = 14695981039346656037uL
        client.frame().rgba.forEach {
            hash = (hash xor (it.toInt() and 255).toULong()) * 1099511628211uL
        }
        assertEquals(24, frames)
        assertEquals(1600, client.width)
        assertEquals(1200, client.height)
        assertEquals(3000278177406984333uL, hash)
        assertTrue(reads > 1000)
    }
}
