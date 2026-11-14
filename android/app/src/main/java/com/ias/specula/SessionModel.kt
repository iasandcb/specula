package com.ias.specula

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel

class SessionModel(app: Application) : AndroidViewModel(app) {
    var host by mutableStateOf("")
    var username by mutableStateOf("")
    var password by mutableStateOf("")
    var message by mutableStateOf("")
    var connected by mutableStateOf(false)
    var connecting by mutableStateOf(false)
    var bitmap by mutableStateOf<Bitmap?>(null)
    var pairing by mutableStateOf(false)
    var settings by mutableStateOf(false)
    var snapshot by mutableStateOf<DisplaySnapshot?>(null)
    var busy by mutableStateOf(false)
    var portrait by mutableStateOf(false)
    private var store: SecureStore? = null
    @Volatile private var client: RfbClient? = null
    private var helper: DisplayClient? = null
    private var connection: Job? = null
    private var heartbeat: Job? = null
    private var rotationAfterPairing = false
    private val events = Channel<Pair<RfbClient, suspend (RfbClient) -> Unit>>(Channel.UNLIMITED)

    val commandTab = CommandTab(::key) { milliseconds ->
        client?.let { target -> events.trySend(target to { delay(milliseconds) }) }
    }

    init {
        viewModelScope.launch {
            try {
                store = withContext(Dispatchers.IO) { SecureStore(app) }
                host = store?.get("host") ?: ""
                username = store?.get("username:$host") ?: ""
                password = store?.get("password:$host") ?: ""
            } catch (e: Exception) {
                message = "연결 정보를 안전하게 열지 못했습니다."
            }
        }
        viewModelScope.launch(Dispatchers.IO) {
            for ((target, event) in events) try {
                if (client === target) event(target)
            } catch (e: Exception) {
                withContext(Dispatchers.Main) { message = "키·포인터 전송에 실패했습니다." }
            }
        }
    }

    fun loadHost() {
        viewModelScope.launch {
            password = withContext(Dispatchers.IO) { store?.get("password:${host.trim()}") ?: "" }
            username = store?.get("username:${host.trim()}") ?: ""
        }
    }

    fun connect() {
        if (connecting || connected) return
        val target = host.trim()
        val user = username
        val pass = password
        if (target.isEmpty()) {
            message = "맥 주소를 입력해 주세요."
            return
        }
        connecting = true
        pairing = false
        settings = false
        snapshot = null
        portrait = false
        rotationAfterPairing = false
        message = "맥에 접속 중…"
        val rfb = RfbClient()
        client = rfb
        connection =
            viewModelScope.launch {
                try {
                    val secrets = store ?: throw java.io.IOException("연결 정보를 안전하게 열지 못했습니다.")
                    withContext(Dispatchers.IO) {
                        secrets.put("host", target)
                        secrets.put("username:$target", user)
                        secrets.put("password:$target", pass)
                    }
                    helper = DisplayClient(target, secrets)
                    withContext(Dispatchers.IO) {
                        rfb.run(
                            target,
                            user,
                            pass,
                            onReady = {
                                viewModelScope.launch {
                                    if (client !== rfb) return@launch
                                    connecting = false
                                    connected = true
                                    message = ""
                                    startHeartbeat()
                                }
                            },
                            onFrame = { frame ->
                                val colors =
                                    IntArray(frame.width * frame.height) { i ->
                                        val p = i * 4
                                        (255 shl 24) or
                                            ((frame.rgba[p].toInt() and 255) shl 16) or
                                            ((frame.rgba[p + 1].toInt() and 255) shl 8) or
                                            (frame.rgba[p + 2].toInt() and 255)
                                    }
                                val image =
                                    Bitmap.createBitmap(
                                        colors,
                                        frame.width,
                                        frame.height,
                                        Bitmap.Config.ARGB_8888,
                                    )
                                viewModelScope.launch { if (client === rfb) bitmap = image }
                            },
                        )
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    message =
                        e.message?.takeIf { it.any { c -> c in '가'..'힣' } }
                            ?: "맥에 연결할 수 없습니다. 주소와 화면 공유 설정을 확인해 주세요."
                } finally {
                    commandTab.release()
                    rfb.close()
                    connecting = false
                    connected = false
                    heartbeat?.cancel()
                    bitmap = null
                    if (client === rfb) client = null
                    restoreHelper()
                }
            }
    }

    private fun startHeartbeat() {
        heartbeat?.cancel()
        heartbeat =
            viewModelScope.launch {
                action {
                    helper?.rotation()?.let { portrait = it.getInt("degrees") in listOf(90, 270) }
                }
                while (isActive) {
                    action { helper?.heartbeat() }
                    delay(15000)
                }
            }
    }

    private fun restoreHelper() {
        val h = helper ?: return
        viewModelScope.launch { action { h.restore() } }
    }

    fun disconnect() {
        commandTab.release()
        val target = client ?: return
        val job = connection
        // Drain the ordered modifier release before closing the socket.
        events.trySend(target to {
            it.close()
            job?.cancel()
        })
    }

    private suspend fun action(block: suspend () -> Unit) {
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: PairingRequired) {
            pairing = true
            settings = true
            snapshot = null
            message = e.message ?: ""
        } catch (e: Exception) {
            message =
                e.message?.takeIf { it.any { c -> c in '가'..'힣' } } ?: "맥의 해상도 보조 앱에 연결할 수 없습니다."
        }
    }

    fun display(block: suspend (DisplayClient) -> Unit) {
        if (busy) return
        viewModelScope.launch {
            busy = true
            message = ""
            try {
                action { helper?.let { block(it) } }
            } finally {
                busy = false
            }
        }
    }

    fun modes() {
        settings = true
        display { snapshot = it.modes() }
    }

    fun pair(code: String) = display {
        it.pair(code)
        pairing = false
        snapshot = it.modes()
        if (rotationAfterPairing) {
            rotationAfterPairing = false
            portrait = it.rotate() in listOf(90, 270)
        }
    }

    fun closeSettings() {
        settings = false
        rotationAfterPairing = false
    }

    fun change(id: Long) = display { snapshot = it.change(id) }

    fun rotate() = display {
        rotationAfterPairing = true
        portrait = it.rotate() in listOf(90, 270)
        rotationAfterPairing = false
    }

    fun pointer(x: Int, y: Int, buttons: Int) {
        client?.let { target -> events.trySend(target to { it.pointer(x, y, buttons) }) }
    }

    fun key(symbol: Int, down: Boolean) {
        client?.let { target -> events.trySend(target to { it.key(symbol, down) }) }
    }

    fun text(text: String) {
        text.codePoints().forEach { cp ->
            val symbol =
                when (cp) {
                    10 -> 0xff0d
                    9 -> 0xff09
                    in 0..255 -> cp
                    else -> 0x01000000 or cp
                }
            key(symbol, true)
            key(symbol, false)
        }
    }

    fun inputSource() {
        key(0xffe3, true)
        key(32, true)
        key(32, false)
        key(0xffe3, false)
    }

    override fun onCleared() {
        client?.close()
        events.close()
        super.onCleared()
    }
}
