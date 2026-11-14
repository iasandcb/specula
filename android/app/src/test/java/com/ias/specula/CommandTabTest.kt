package com.ias.specula

import org.junit.Assert.*
import org.junit.Test

class CommandTabTest {
    private val events = mutableListOf<String>()
    private val switcher = CommandTab(
        send = { symbol, down -> events.add("$symbol:$down") },
        pause = { milliseconds -> events.add("wait:$milliseconds") },
    )

    @Test
    fun firstTapHoldsCommandWithModifierGapBeforeTab() {
        assertFalse(switcher.held)
        switcher.tap()
        assertTrue(switcher.held)
        assertEquals(listOf("65515:true", "wait:40", "65289:true", "65289:false"), events)
    }

    @Test
    fun furtherTapsOnlySendTab() {
        switcher.tap()
        events.clear()
        repeat(3) { switcher.tap() }
        assertTrue(switcher.held)
        assertEquals(List(3) { listOf("65289:true", "65289:false") }.flatten(), events)
    }

    @Test
    fun releaseIsIdempotentAndSendsCommandUp() {
        switcher.release()
        assertTrue(events.isEmpty())
        switcher.tap()
        events.clear()
        switcher.release()
        switcher.release()
        assertFalse(switcher.held)
        assertEquals(listOf("65515:false"), events)
    }

    @Test
    fun releaseBeforeDelayCompletesIsOrderedBeforeNextSession() {
        // These callbacks enqueue work, so a release can arrive while the sender is waiting.
        switcher.tap()
        switcher.tap()
        switcher.release()
        switcher.tap()
        switcher.release()
        assertFalse(switcher.held)
        assertEquals(
            listOf(
                "65515:true", "wait:40", "65289:true", "65289:false",
                "65289:true", "65289:false", "65515:false",
                "65515:true", "wait:40", "65289:true", "65289:false", "65515:false",
            ),
            events,
        )
    }
}
