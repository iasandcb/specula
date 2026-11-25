package com.ias.specula

import java.io.*
import java.math.BigInteger
import java.net.ServerSocket
import java.security.MessageDigest
import java.util.concurrent.*
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.*
import org.junit.Test

class SessionTest {
    private fun session(minor: Int, account: Boolean, compressed: Boolean) {
        ServerSocket(0).use { listener ->
            val executor = Executors.newSingleThreadExecutor()
            val server =
                executor.submit<Unit> {
                    listener.accept().use { socket ->
                        socket.soTimeout = 5000
                        val input = DataInputStream(socket.getInputStream())
                        val out = socket.getOutputStream()
                        fun send(bytes: ByteArray) {
                            bytes.forEach {
                                out.write(it.toInt())
                                out.flush()
                            }
                        }
                        fun read(n: Int) = ByteArray(n).also(input::readFully)
                        send("RFB 003.00$minor\n".toByteArray())
                        assertEquals("RFB 003.00$minor\n", read(12).toString(Charsets.US_ASCII))
                        val type = if (account) 30 else 2
                        if (minor == 3) send(Wire.packet { writeInt(type) })
                        else {
                            send(byteArrayOf(1, type.toByte()))
                            assertEquals(type, input.readUnsignedByte())
                        }
                        if (account) {
                            val p = BigInteger(1, ArdTest.prime)
                            val exponent = BigInteger.valueOf(12345)
                            val peer = ARD.padded(BigInteger.valueOf(2).modPow(exponent, p), 128)
                            send(
                                Wire.packet {
                                    writeShort(2)
                                    writeShort(128)
                                    write(ArdTest.prime)
                                    write(peer)
                                }
                            )
                            val encrypted = read(128)
                            val publicKey = BigInteger(1, read(128))
                            val shared = ARD.padded(publicKey.modPow(exponent, p), 128)
                            val block =
                                Cipher.getInstance("AES/ECB/NoPadding").run {
                                    init(
                                        Cipher.DECRYPT_MODE,
                                        SecretKeySpec(
                                            MessageDigest.getInstance("MD5").digest(shared),
                                            "AES",
                                        ),
                                    )
                                    doFinal(encrypted)
                                }
                            assertEquals("alex", block.copyOfRange(0, 4).toString(Charsets.UTF_8))
                            assertEquals(0, block[4].toInt())
                            assertEquals(
                                "암호123",
                                block.copyOfRange(64, 73).toString(Charsets.UTF_8),
                            )
                        } else {
                            send(ByteArray(16))
                            assertArrayEquals(hex("8ca64de9c1b123a78ca64de9c1b123a7"), read(16))
                        }
                        send(ByteArray(4))
                        assertEquals(1, input.readUnsignedByte())
                        send(
                            Wire.packet {
                                writeShort(2)
                                writeShort(1)
                                write(Wire.format)
                                writeInt(4)
                                writeBytes("Test")
                            }
                        )
                        assertArrayEquals(byteArrayOf(0, 0, 0, 0) + Wire.format, read(20))
                        assertArrayEquals(Wire.encodings, read(Wire.encodings.size))
                        assertArrayEquals(hex("03000000000000020001"), read(10))
                        send(
                            Wire.packet {
                                writeByte(0)
                                writeByte(0)
                                writeShort(1)
                                writeShort(0)
                                writeShort(0)
                                writeShort(2)
                                writeShort(1)
                                writeInt(if (compressed) 16 else 0)
                                if (compressed) {
                                    val deflater = java.util.zip.Deflater()
                                    deflater.setInput(hex("00ff000000ff00"))
                                    val b = ByteArray(100)
                                    val n =
                                        deflater.deflate(
                                            b,
                                            0,
                                            b.size,
                                            java.util.zip.Deflater.SYNC_FLUSH,
                                        )
                                    writeInt(n)
                                    write(b, 0, n)
                                    deflater.end()
                                } else write(hex("ff00000000ff0000"))
                            }
                        )
                        assertArrayEquals(hex("03010000000000020001"), read(10))
                        assertArrayEquals(Wire.key(0xffe3, true), read(8))
                        assertArrayEquals(Wire.pointer(1, 0, 4), read(6))
                        assertArrayEquals(Wire.pointer(1, 0, 0), read(6))
                    }
                }
            val client = RfbClient()
            var frames = 0
            var ready = false
            try {
                client.run(
                    "127.0.0.1",
                    if (account) "alex" else "",
                    if (account) "암호123" else "\u0000",
                    listener.localPort,
                    onReady = {
                        assertEquals("Test", it)
                        ready = true
                    },
                    onFrame = { frame ->
                        frames++
                        assertEquals(2, frame.width)
                        assertEquals(1, frame.height)
                        assertArrayEquals(hex("ff0000ff00ff00ff"), frame.rgba)
                        client.key(0xffe3, true)
                        client.pointer(99, -1, 4)
                        client.pointer(1, 0, 0)
                    },
                )
            } catch (expected: EOFException) {
                /* server closed after the update */
            } finally {
                client.close()
                executor.shutdown()
            }
            server.get(10, TimeUnit.SECONDS)
            assertEquals(1, frames)
            assertTrue(ready)
        }
    }

    @Test fun fragmentedVnc38Raw() = session(8, false, false)

    @Test fun fragmentedArd38Raw() = session(8, true, false)

    @Test fun fragmentedVnc33Zrle() = session(3, false, true)

    @Test fun fragmentedVnc37Raw() = session(7, false, false)

    @Test
    fun securityMismatchIsRejected() {
        ServerSocket(0).use { listener ->
            val thread = Thread {
                listener.accept().use { s ->
                    s.getOutputStream().write("RFB 003.008\n".toByteArray())
                    DataInputStream(s.getInputStream()).readFully(ByteArray(12))
                    s.getOutputStream().write(byteArrayOf(1, 1))
                }
            }
            thread.start()
            val c = RfbClient()
            assertThrows(IOException::class.java) {
                c.run("127.0.0.1", "", "secret", listener.localPort) {}
            }
            c.close()
            thread.join(5000)
        }
    }
}
