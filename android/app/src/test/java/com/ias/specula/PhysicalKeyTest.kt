package com.ias.specula

import android.view.KeyEvent
import org.junit.Assert.*
import org.junit.Test

class PhysicalKeyTest {
    @Test
    fun lettersAndDigitsUseUsPositions() {
        for (i in 0..25) {
            assertEquals('a'.code + i, PhysicalKey.fromKeyCode(KeyEvent.KEYCODE_A + i))
            assertEquals('A'.code + i, PhysicalKey.fromKeyCode(KeyEvent.KEYCODE_A + i, shift = true))
        }
        for (i in 0..8) {
            assertEquals('1'.code + i, PhysicalKey.fromKeyCode(KeyEvent.KEYCODE_1 + i))
            assertEquals("!@#$%^&*("[i].code, PhysicalKey.fromKeyCode(KeyEvent.KEYCODE_1 + i, shift = true))
        }
        assertEquals('0'.code, PhysicalKey.fromKeyCode(KeyEvent.KEYCODE_0))
        assertEquals(')'.code, PhysicalKey.fromKeyCode(KeyEvent.KEYCODE_0, shift = true))
    }

    @Test
    fun punctuationUsesUsPositionsWithShift() {
        val codes = listOf(
            KeyEvent.KEYCODE_MINUS, KeyEvent.KEYCODE_EQUALS, KeyEvent.KEYCODE_LEFT_BRACKET,
            KeyEvent.KEYCODE_RIGHT_BRACKET, KeyEvent.KEYCODE_BACKSLASH, KeyEvent.KEYCODE_SEMICOLON,
            KeyEvent.KEYCODE_APOSTROPHE, KeyEvent.KEYCODE_GRAVE, KeyEvent.KEYCODE_COMMA,
            KeyEvent.KEYCODE_PERIOD, KeyEvent.KEYCODE_SLASH,
        )
        val plain = "-=[]\\;'`,./"
        val shifted = "_+{}|:\"~<>?"
        codes.forEachIndexed { i, code ->
            assertEquals(plain[i].code, PhysicalKey.fromKeyCode(code))
            assertEquals(shifted[i].code, PhysicalKey.fromKeyCode(code, shift = true))
        }
        // Apple's Option-bracket handling matches Swift and is keyed by Meta, not Android Alt.
        assertEquals(0x0100201c, PhysicalKey.fromKeyCode(KeyEvent.KEYCODE_LEFT_BRACKET, option = true))
        assertEquals(0x01002019, PhysicalKey.fromKeyCode(KeyEvent.KEYCODE_RIGHT_BRACKET, shift = true, option = true))
    }

    @Test
    fun specialKeysAndModifiersMatchMacKeysyms() {
        val expected = mapOf(
            KeyEvent.KEYCODE_ENTER to 0xff0d,
            KeyEvent.KEYCODE_NUMPAD_ENTER to 0xff0d,
            KeyEvent.KEYCODE_DEL to 0xff08,
            KeyEvent.KEYCODE_TAB to 0xff09,
            KeyEvent.KEYCODE_ESCAPE to 0xff1b,
            KeyEvent.KEYCODE_DPAD_LEFT to 0xff51,
            KeyEvent.KEYCODE_DPAD_UP to 0xff52,
            KeyEvent.KEYCODE_DPAD_RIGHT to 0xff53,
            KeyEvent.KEYCODE_DPAD_DOWN to 0xff54,
            KeyEvent.KEYCODE_FORWARD_DEL to 0xffff,
            KeyEvent.KEYCODE_MOVE_HOME to 0xff50,
            KeyEvent.KEYCODE_MOVE_END to 0xff57,
            KeyEvent.KEYCODE_PAGE_UP to 0xff55,
            KeyEvent.KEYCODE_PAGE_DOWN to 0xff56,
            KeyEvent.KEYCODE_SPACE to 32,
            KeyEvent.KEYCODE_SHIFT_LEFT to 0xffe1,
            KeyEvent.KEYCODE_SHIFT_RIGHT to 0xffe2,
            KeyEvent.KEYCODE_CTRL_LEFT to 0xffe3,
            KeyEvent.KEYCODE_CTRL_RIGHT to 0xffe4,
            KeyEvent.KEYCODE_ALT_LEFT to 0xffeb,
            KeyEvent.KEYCODE_ALT_RIGHT to 0xffeb,
            KeyEvent.KEYCODE_META_LEFT to 0xffe7,
            KeyEvent.KEYCODE_META_RIGHT to 0xffe7,
        )
        expected.forEach { (code, symbol) ->
            assertEquals("keyCode $code", symbol, PhysicalKey.fromKeyCode(code))
            assertEquals("shifted keyCode $code", symbol, PhysicalKey.fromKeyCode(code, shift = true))
        }
        assertNull(PhysicalKey.fromKeyCode(KeyEvent.KEYCODE_UNKNOWN))
    }

}
