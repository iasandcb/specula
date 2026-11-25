package com.ias.specula

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Calls enqueue in order; pause must use the same send queue as key events. */
class CommandTab(
    private val send: (Int, Boolean) -> Unit,
    private val pause: (Long) -> Unit,
) {
    var held by mutableStateOf(false)
        private set

    fun tap() {
        if (!held) {
            held = true
            send(PhysicalKey.COMMAND, true)
            pause(40)
        }
        send(0xff09, true)
        send(0xff09, false)
    }

    fun release() {
        if (!held) return
        held = false
        send(PhysicalKey.COMMAND, false)
    }
}
