package com.ias.specula

import java.io.DataInputStream
import java.net.ServerSocket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DisplayClientTest {
    private class Memory : Secrets {
        val values = ConcurrentHashMap<String, String>()

        override fun get(key: String) = values[key]

        override fun put(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }

    @Test
    fun pairModeRotationHeartbeatRestoreAndUnauthorized(): Unit = runBlocking {
        val secrets = Memory()
        var status = 200
        val paths = mutableListOf<String>()
        var angle = 0
        val mode = """{"id":42,"width":1280,"height":720,"pixelWidth":2560,"pixelHeight":1440}"""
        val snapshot = """{"current":$mode,"modes":[$mode,$mode]}"""
        val server = ServerSocket(0)
        val executor = Executors.newSingleThreadExecutor()
        val served =
            executor.submit<Unit> {
                repeat(11) {
                    server.accept().use { socket ->
                        socket.soTimeout = 5000
                        val input = DataInputStream(socket.getInputStream())
                        fun line(): String {
                            val out = StringBuilder()
                            while (true) {
                                val b = input.readUnsignedByte()
                                if (b == 10) break
                                if (b != 13) out.append(b.toChar())
                            }
                            return out.toString()
                        }
                        val request = line().split(" ")
                        val method = request[0]
                        val path = request[1]
                        paths.add(path)
                        val headers = mutableMapOf<String, String>()
                        while (true) {
                            val l = line()
                            if (l.isEmpty()) break
                            headers[l.substringBefore(":").lowercase()] =
                                l.substringAfter(":").trim()
                        }
                        val body =
                            ByteArray(headers["content-length"]?.toInt() ?: 0)
                                .also(input::readFully)
                                .toString(Charsets.UTF_8)
                        var result = "{}"
                        if (path == "/pair") {
                            assertEquals("POST", method)
                            assertEquals("123456", JSONObject(body).getString("code"))
                            result = """{"token":"fresh"}"""
                        } else {
                            assertEquals("Bearer fresh", headers["authorization"])
                            when (path) {
                                "/modes" -> {
                                    assertEquals("GET", method)
                                    result = snapshot
                                }
                                "/mode" -> {
                                    assertEquals(42, JSONObject(body).getInt("modeID"))
                                    result = snapshot
                                }
                                "/rotation" -> {
                                    if (method == "POST") angle = JSONObject(body).getInt("degrees")
                                    result = """{"degrees":$angle,"supported":true}"""
                                }
                                "/heartbeat",
                                "/restore" -> {
                                    assertEquals("POST", method)
                                    JSONObject(body)
                                }
                            }
                        }
                        if (status != 200) result = """{"message":"다시 연결해 주세요."}"""
                        val bytes = result.toByteArray()
                        socket.getOutputStream().apply {
                            write(
                                "HTTP/1.1 $status Response\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
                                    .toByteArray()
                            )
                            write(bytes)
                            flush()
                        }
                    }
                }
            }
        try {
            val client = DisplayClient("127.0.0.1", secrets, server.localPort)
            client.pair("123456")
            assertEquals("fresh", secrets.get("token:127.0.0.1"))
            val snap = client.modes()
            assertEquals(42L, snap.current.id)
            assertEquals(1, snap.modes.size)
            client.change(42)
            assertEquals(90, client.rotate())
            assertEquals(0, client.rotate())
            client.heartbeat()
            client.restore()
            assertTrue(
                paths.containsAll(
                    listOf("/pair", "/modes", "/mode", "/rotation", "/heartbeat", "/restore")
                )
            )
            status = 401
            try {
                client.heartbeat()
                fail("401 must request pairing")
            } catch (expected: PairingRequired) {
                assertNull(secrets.get("token:127.0.0.1"))
            }
            secrets.put("token:127.0.0.1", "old")
            try {
                client.pair("123456")
                fail("Wrong code must request pairing")
            } catch (expected: PairingRequired) {
                assertNull(secrets.get("token:127.0.0.1"))
            }
            served.get(10, TimeUnit.SECONDS)
        } finally {
            server.close()
            executor.shutdownNow()
        }
    }

    @Test
    fun listFailsFastOnUnresponsiveHelper(): Unit = runBlocking {
        java.net.ServerSocket(0).use { listener ->
            val thread = Thread { listener.accept().use { Thread.sleep(1200) } }
            thread.start()
            val client = DisplayClient("127.0.0.1", Memory(), listener.localPort)
            val start = System.nanoTime()
            try {
                client.call("/modes", timeout = 200)
                fail("must time out")
            } catch (expected: java.net.SocketTimeoutException) {
                assertTrue((System.nanoTime() - start) / 1000000 < 1000)
            }
            thread.join(2000)
        }
    }
}
