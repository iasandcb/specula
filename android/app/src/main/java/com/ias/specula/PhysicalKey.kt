package com.ias.specula

import android.view.KeyEvent

/** Swift PhysicalKey's US ANSI HID map. Apple expects Meta for Option and Super for Command. */
object PhysicalKey {
    const val COMMAND = 0xffeb // Super_L, matching the Swift Command button.
    const val OPTION = 0xffe7 // Meta_L: Apple Screen Sharing interprets this as Option.

    /** Android physical positions, independent of Android's layout, Unicode and composing IME. */
    fun fromKeyCode(keyCode: Int, shift: Boolean = false, option: Boolean = false): Int? {
        // Alt+Tab and Meta+Tab are intercepted by Android and cannot be received by the app.
        when (keyCode) {
            KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT -> return COMMAND
            KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_META_RIGHT -> return OPTION
        }
        val hid = when (keyCode) {
            in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> keyCode - KeyEvent.KEYCODE_A + 4
            in KeyEvent.KEYCODE_1..KeyEvent.KEYCODE_9 -> keyCode - KeyEvent.KEYCODE_1 + 30
            KeyEvent.KEYCODE_0 -> 39
            else -> androidHid[keyCode] ?: return null
        }
        return symbol(hid, shift, option)
    }

    private val androidHid = mapOf(
        KeyEvent.KEYCODE_ENTER to 40,
        KeyEvent.KEYCODE_NUMPAD_ENTER to 40,
        KeyEvent.KEYCODE_ESCAPE to 41,
        KeyEvent.KEYCODE_DEL to 42,
        KeyEvent.KEYCODE_TAB to 43,
        KeyEvent.KEYCODE_SPACE to 44,
        KeyEvent.KEYCODE_MINUS to 45,
        KeyEvent.KEYCODE_EQUALS to 46,
        KeyEvent.KEYCODE_LEFT_BRACKET to 47,
        KeyEvent.KEYCODE_RIGHT_BRACKET to 48,
        KeyEvent.KEYCODE_BACKSLASH to 49,
        KeyEvent.KEYCODE_SEMICOLON to 51,
        KeyEvent.KEYCODE_APOSTROPHE to 52,
        KeyEvent.KEYCODE_GRAVE to 53,
        KeyEvent.KEYCODE_COMMA to 54,
        KeyEvent.KEYCODE_PERIOD to 55,
        KeyEvent.KEYCODE_SLASH to 56,
        KeyEvent.KEYCODE_CAPS_LOCK to 57,
        KeyEvent.KEYCODE_MOVE_HOME to 74,
        KeyEvent.KEYCODE_PAGE_UP to 75,
        KeyEvent.KEYCODE_FORWARD_DEL to 76,
        KeyEvent.KEYCODE_MOVE_END to 77,
        KeyEvent.KEYCODE_PAGE_DOWN to 78,
        KeyEvent.KEYCODE_DPAD_RIGHT to 79,
        KeyEvent.KEYCODE_DPAD_LEFT to 80,
        KeyEvent.KEYCODE_DPAD_DOWN to 81,
        KeyEvent.KEYCODE_DPAD_UP to 82,
        KeyEvent.KEYCODE_CTRL_LEFT to 224,
        KeyEvent.KEYCODE_SHIFT_LEFT to 225,
        KeyEvent.KEYCODE_CTRL_RIGHT to 228,
        KeyEvent.KEYCODE_SHIFT_RIGHT to 229,
    )

    fun symbol(hid: Int, shift: Boolean = false, option: Boolean = false): Int? {
        if (option && hid == 47) return if (shift) 0x0100201d else 0x0100201c
        if (option && hid == 48) return if (shift) 0x01002019 else 0x01002018
        if (hid in 4..29) return (if (shift) 65 else 97) + hid - 4
        if (shift && hid in 30..39) return "!@#$%^&*()"[hid - 30].code
        if (hid in 30..38) return 49 + hid - 30
        if (shift)
            mapOf(
                    45 to 95,
                    46 to 43,
                    47 to 123,
                    48 to 125,
                    49 to 124,
                    51 to 58,
                    52 to 34,
                    53 to 126,
                    54 to 60,
                    55 to 62,
                    56 to 63,
                )[hid]
                ?.let {
                    return it
                }
        return mapOf(
            39 to 48,
            40 to 0xff0d,
            41 to 0xff1b,
            42 to 0xff08,
            43 to 0xff09,
            44 to 32,
            45 to 45,
            46 to 61,
            47 to 91,
            48 to 93,
            49 to 92,
            51 to 59,
            52 to 39,
            53 to 96,
            54 to 44,
            55 to 46,
            56 to 47,
            57 to 0xffe5,
            74 to 0xff50,
            75 to 0xff55,
            76 to 0xffff,
            77 to 0xff57,
            78 to 0xff56,
            79 to 0xff53,
            80 to 0xff51,
            81 to 0xff54,
            82 to 0xff52,
            224 to 0xffe3,
            225 to 0xffe1,
            226 to 0xffeb,
            227 to 0xffeb,
            228 to 0xffe4,
            229 to 0xffe2,
            230 to 0xffe7,
            231 to 0xffec,
        )[hid]
    }
}
