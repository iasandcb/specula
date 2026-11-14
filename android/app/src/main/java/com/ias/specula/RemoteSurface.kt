package com.ias.specula

import android.content.Context
import android.graphics.*
import android.text.InputType
import android.view.*
import android.view.inputmethod.*
import kotlin.math.hypot

/** One finger controls the Mac; two fingers transform the viewport or right-click. */
class RemoteSurface(context: Context) : View(context) {
    var frame: Bitmap? = null
        set(value) {
            if (field?.width != value?.width || field?.height != value?.height) {
                zoom = 1f
                panX = 0f
                panY = 0f
            }
            field = value
            invalidate()
        }

    var pointer: (Int, Int, Int) -> Unit = { _, _, _ -> }
    var key: (Int, Boolean) -> Unit = { _, _ -> }
    var text: (String) -> Unit = {}
    var keyboard = false
    private var zoom = 1f
    private var panX = 0f
    private var panY = 0f
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var multi = false
    private var moved = false
    private var dragging = false
    private var startTime = 0L
    private var distance = 0f
    private var centerX = 0f
    private var centerY = 0f
    private var initialDistance = 0f
    private var initialCenterX = 0f
    private var initialCenterY = 0f
    private val heldKeys = mutableMapOf<Pair<Int, Int>, Int>()
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        contentDescription = "맥 원격 화면. 한 손가락으로 클릭·드래그, 두 손가락으로 확대·이동 또는 오른쪽 클릭"
    }

    private fun scale(): Float {
        val f = frame ?: return 1f
        return minOf(width.toFloat() / f.width, height.toFloat() / f.height) * zoom
    }

    private fun origin(): Pair<Float, Float> {
        val f = frame ?: return 0f to 0f
        val s = scale()
        return (width - f.width * s) / 2 + panX to (height - f.height * s) / 2 + panY
    }

    private fun send(x: Float, y: Float, mask: Int) {
        val f = frame ?: return
        val (ox, oy) = origin()
        val s = scale()
        pointer(
            ((x - ox) / s).toInt().coerceIn(0, f.width - 1),
            ((y - oy) / s).toInt().coerceIn(0, f.height - 1),
            mask,
        )
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawColor(Color.BLACK)
        frame?.let {
            val (x, y) = origin()
            canvas.save()
            canvas.translate(x, y)
            canvas.scale(scale(), scale())
            canvas.drawBitmap(it, 0f, 0f, paint)
            canvas.restore()
        }
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                requestFocus()
                downX = e.x
                downY = e.y
                lastX = e.x
                lastY = e.y
                moved = false
                multi = false
                dragging = false
                startTime = e.eventTime
                parent.requestDisallowInterceptTouchEvent(true)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                if (dragging) send(lastX, lastY, 0)
                dragging = false
                multi = true
                if (e.pointerCount == 2) {
                    distance = hypot(e.getX(0) - e.getX(1), e.getY(0) - e.getY(1))
                    centerX = (e.getX(0) + e.getX(1)) / 2
                    centerY = (e.getY(0) + e.getY(1)) / 2
                    initialDistance = distance
                    initialCenterX = centerX
                    initialCenterY = centerY
                }
            }
            MotionEvent.ACTION_MOVE ->
                if (e.pointerCount >= 2) {
                    val cx = (e.getX(0) + e.getX(1)) / 2
                    val cy = (e.getY(0) + e.getY(1)) / 2
                    val d = hypot(e.getX(0) - e.getX(1), e.getY(0) - e.getY(1))
                    if (
                        hypot(cx - initialCenterX, cy - initialCenterY) >
                            ViewConfiguration.get(context).scaledTouchSlop ||
                            kotlin.math.abs(d - initialDistance) >
                                ViewConfiguration.get(context).scaledTouchSlop
                    )
                        moved = true
                    val old = scale()
                    val (ox, oy) = origin()
                    zoom = (zoom * (if (distance > 0) d / distance else 1f)).coerceIn(1f, 8f)
                    val ratio = scale() / old
                    // Keep the remote point under the two-finger centroid while zooming.
                    val f = frame
                    if (f != null) {
                        panX = cx - (centerX - ox) * ratio - (width - f.width * scale()) / 2
                        panY = cy - (centerY - oy) * ratio - (height - f.height * scale()) / 2
                    }
                    distance = d
                    centerX = cx
                    centerY = cy
                    invalidate()
                } else if (!multi) {
                    if (
                        !dragging &&
                            hypot(e.x - downX, e.y - downY) >
                                ViewConfiguration.get(context).scaledTouchSlop
                    ) {
                        dragging = true
                        moved = true
                        send(downX, downY, 1)
                    }
                    send(e.x, e.y, if (dragging) 1 else 0)
                    lastX = e.x
                    lastY = e.y
                }
            MotionEvent.ACTION_UP -> {
                if (dragging) send(e.x, e.y, 0)
                else if (!moved && e.eventTime - startTime < 500) {
                    val mask = if (multi) 4 else 1
                    send(downX, downY, mask)
                    send(downX, downY, 0)
                    performClick()
                }
                parent.requestDisallowInterceptTouchEvent(false)
            }
            MotionEvent.ACTION_CANCEL -> {
                if (dragging) send(lastX, lastY, 0)
                dragging = false
                parent.requestDisallowInterceptTouchEvent(false)
            }
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    fun showKeyboard(show: Boolean) {
        keyboard = show
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        if (show) {
            requestFocus()
            imm.restartInput(this)
            imm.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
        } else imm.hideSoftInputFromWindow(windowToken, 0)
    }

    override fun onCheckIsTextEditor() = keyboard

    override fun onCreateInputConnection(info: EditorInfo): InputConnection {
        info.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        info.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
        return object : BaseInputConnection(this, false) {
            // Composition is local until committed, preventing duplicate Korean syllables.
            override fun setComposingText(value: CharSequence?, newCursorPosition: Int) = true

            override fun commitText(value: CharSequence?, newCursorPosition: Int): Boolean {
                text(value?.toString() ?: "")
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                repeat(beforeLength.coerceAtMost(100)) {
                    key(0xff08, true)
                    key(0xff08, false)
                }
                repeat(afterLength.coerceAtMost(100)) {
                    key(0xffff, true)
                    key(0xffff, false)
                }
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean = handleKey(event)
        }
    }

    private fun isPhysical(event: KeyEvent): Boolean =
        event.deviceId != KeyCharacterMap.VIRTUAL_KEYBOARD &&
            event.flags and KeyEvent.FLAG_SOFT_KEYBOARD == 0 &&
            event.isFromSource(InputDevice.SOURCE_KEYBOARD)

    // onKeyDown alone runs AFTER the IME. Consume here so physical input can never
    // become a later commitText as well. Soft IME composition/commits stay independent.
    override fun onKeyPreIme(keyCode: Int, event: KeyEvent): Boolean =
        (isPhysical(event) && handleKey(event)) || super.onKeyPreIme(keyCode, event)

    // Also consume Tab/arrows before View focus navigation when no IME is active.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        (isPhysical(event) && handleKey(event)) || super.dispatchKeyEvent(event)

    private fun symbol(event: KeyEvent): Int? {
        PhysicalKey.fromKeyCode(event.keyCode, event.isShiftPressed, event.isMetaPressed)
            ?.let { return it }
        if (isPhysical(event)) return null
        // Some soft keyboards send virtual KeyEvents instead of commitText.
        val c = event.unicodeChar
        return if (c == 0) null else if (c <= 255) c else 0x01000000 or c
    }

    private fun handleKey(event: KeyEvent): Boolean {
        val identity = event.deviceId to event.keyCode
        if (event.action == KeyEvent.ACTION_DOWN) {
            val s = heldKeys[identity] ?: symbol(event) ?: return false
            heldKeys[identity] = s
            key(s, true)
            return true
        }
        if (event.action == KeyEvent.ACTION_UP) {
            val s = heldKeys.remove(identity) ?: symbol(event) ?: return false
            key(s, false)
            return true
        }
        return false
    }

    override fun onFocusChanged(gainFocus: Boolean, direction: Int, previouslyFocusedRect: Rect?) {
        if (!gainFocus) releaseKeys()
        super.onFocusChanged(gainFocus, direction, previouslyFocusedRect)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent) =
        handleKey(event) || super.onKeyDown(keyCode, event)

    override fun onKeyUp(keyCode: Int, event: KeyEvent) =
        handleKey(event) || super.onKeyUp(keyCode, event)

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        if (!hasWindowFocus) releaseKeys()
        super.onWindowFocusChanged(hasWindowFocus)
    }

    private fun releaseKeys() {
        heldKeys.values.forEach { key(it, false) }
        heldKeys.clear()
    }

    override fun onDetachedFromWindow() {
        releaseKeys()
        if (dragging) send(lastX, lastY, 0)
        showKeyboard(false)
        super.onDetachedFromWindow()
    }
}
