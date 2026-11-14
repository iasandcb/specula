package com.ias.specula

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

class PairingRequired(message: String = "맥의 연결 코드로 다시 연결해 주세요.") : IOException(message)

interface Secrets {
    fun get(key: String): String?

    fun put(key: String, value: String?)
}

data class DisplayMode(
    val id: Long,
    val width: Int,
    val height: Int,
    val pixelWidth: Int,
    val pixelHeight: Int,
) {
    val title
        get() = "$width × $height" + if (pixelWidth > width) " · 레티나" else ""
}

data class DisplaySnapshot(val current: DisplayMode, val modes: List<DisplayMode>)

class DisplayClient(
    private val host: String,
    private val secrets: Secrets,
    private val port: Int = 5901,
) {
    private val tokenKey = "token:$host"

    suspend fun call(path: String, body: JSONObject? = null, timeout: Int = 3000): JSONObject =
        withContext(Dispatchers.IO) {
            val connection =
                URI("http", null, host, port, path, null, null).toURL().openConnection()
                    as HttpURLConnection
            try {
                connection.connectTimeout = timeout
                connection.readTimeout = timeout
                connection.instanceFollowRedirects = false
                connection.requestMethod = if (body == null) "GET" else "POST"
                connection.setRequestProperty("Content-Type", "application/json")
                if (path != "/pair")
                    secrets.get(tokenKey)?.let {
                        connection.setRequestProperty("Authorization", "Bearer $it")
                    }
                if (body != null) {
                    connection.doOutput = true
                    connection.outputStream.use { it.write(body.toString().toByteArray()) }
                }
                val status = connection.responseCode
                // Even a rejected pairing code drops any previous bearer, per Android task
                // requirements.
                if (status == 401) {
                    secrets.put(tokenKey, null)
                    throw PairingRequired(
                        if (path == "/pair") "연결 코드를 확인해 주세요." else "맥의 연결 코드로 다시 연결해 주세요."
                    )
                }
                val stream = if (status == 200) connection.inputStream else connection.errorStream
                val text =
                    stream?.use { input ->
                        val bytes = input.readNBytesCompat(1048576)
                        bytes.toString(Charsets.UTF_8)
                    } ?: "{}"
                val json = JSONObject(text)
                if (status != 200)
                    throw IOException(json.optString("message", "맥의 해상도 보조 앱에 연결할 수 없습니다."))
                json
            } finally {
                connection.disconnect()
            }
        }

    suspend fun pair(code: String) {
        val result = call("/pair", JSONObject().put("code", code))
        secrets.put(tokenKey, result.getString("token"))
    }

    suspend fun modes() = snapshot(call("/modes"))

    suspend fun change(id: Long) = snapshot(call("/mode", JSONObject().put("modeID", id)))

    suspend fun rotation() = call("/rotation")

    suspend fun rotate(): Int {
        val current = call("/rotation", timeout = 6000).getInt("degrees")
        val next = if (((current % 360) + 360) % 360 == 0) 90 else 0
        val result = call("/rotation", JSONObject().put("degrees", next), 6000)
        if (!result.getBoolean("supported")) throw IOException("이 디스플레이의 화면을 회전하지 못했습니다.")
        return result.getInt("degrees")
    }

    suspend fun heartbeat() {
        call("/heartbeat", JSONObject())
    }

    suspend fun restore() {
        call("/restore", JSONObject())
    }

    private fun snapshot(json: JSONObject): DisplaySnapshot {
        fun mode(j: JSONObject) =
            DisplayMode(
                j.getLong("id"),
                j.getInt("width"),
                j.getInt("height"),
                j.getInt("pixelWidth"),
                j.getInt("pixelHeight"),
            )
        val array = json.getJSONArray("modes")
        val modes =
            (0 until array.length())
                .map { mode(array.getJSONObject(it)) }
                .filter {
                    it.width > 0 &&
                        it.height > 0 &&
                        it.pixelWidth > 0 &&
                        it.pixelHeight > 0 &&
                        it.pixelWidth.toLong() * it.pixelHeight <= 6016L * 3384
                }
                .sortedWith(
                    compareBy(
                        { it.width },
                        { it.height },
                        { it.pixelWidth },
                        { it.pixelHeight },
                        { it.id },
                    )
                )
                .distinctBy { listOf(it.width, it.height, it.pixelWidth, it.pixelHeight) }
        return DisplaySnapshot(mode(json.getJSONObject("current")), modes)
    }
}

private fun java.io.InputStream.readNBytesCompat(cap: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val chunk = ByteArray(4096)
    while (true) {
        val n = read(chunk)
        if (n < 0) break
        requireProtocol(out.size() + n <= cap, "서버 메시지가 너무 큽니다.")
        out.write(chunk, 0, n)
    }
    return out.toByteArray()
}
