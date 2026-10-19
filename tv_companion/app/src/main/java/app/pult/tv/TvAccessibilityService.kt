package app.pult.tv

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Point
import android.media.AudioManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject
import kotlin.math.roundToInt
import kotlin.math.abs

/** Runs only after user turns on the accessibility service in TV settings. */
class TvAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile var instance: TvAccessibilityService? = null
            private set
    }

    private val main = Handler(Looper.getMainLooper())
    private var server: CompanionServer? = null
    private var manager: WindowManager? = null
    private var pointer: CursorView? = null
    private var params: WindowManager.LayoutParams? = null
    private var screenWidth = 1920
    private var screenHeight = 1080
    private var cursorX = 960f
    private var cursorY = 540f
    private var cursorVisible = false

    // A true Accessibility drag uses continued strokes: the button stays
    // pressed while the phone streams cursor deltas, then releases on lift.
    private var dragActive = false
    private var dragBusy = false
    private var dragEnding = false
    private var dragStroke: GestureDescription.StrokeDescription? = null
    private var dragStrokeX = 0f
    private var dragStrokeY = 0f
    private var dragTargetX = 0f
    private var dragTargetY = 0f
    private var scrollBusy = false
    private var scrollPending = 0.0

    private fun resetDrag() {
        dragActive = false
        dragBusy = false
        dragEnding = false
        dragStroke = null
    }

    // Gesture dispatch is asynchronous. Queue scroll distance and dispatch one
    // gesture at a time instead of cancelling an earlier scroll with the next.
    private fun enqueueScroll(amount: Double): JSONObject {
        if (dragActive) return fail("Завершите перетаскивание перед прокруткой")
        scrollPending = (scrollPending + amount).coerceIn(-12.0, 12.0)
        pumpScroll()
        return ok()
    }

    private fun pumpScroll() {
        if (scrollBusy || abs(scrollPending) < .1) return
        val step = scrollPending.coerceIn(-3.0, 3.0)
        scrollPending -= step
        val travel = (135f * abs(step).toFloat()).coerceAtMost(screenHeight * .52f)
        val x = cursorX.coerceIn(12f, (screenWidth - 12).toFloat())
        val middle = cursorY.coerceIn(screenHeight * .3f, screenHeight * .7f)
        val startY = middle + if (step > 0) travel / 2 else -travel / 2
        val endY = middle + if (step > 0) -travel / 2 else travel / 2
        val path = Path().apply { moveTo(x, startY); lineTo(x, endY) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 155L)
        scrollBusy = true
        val accepted = dispatchGesture(
            GestureDescription.Builder().addStroke(stroke).build(),
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    scrollBusy = false
                    pumpScroll()
                }
                override fun onCancelled(gestureDescription: GestureDescription?) {
                    scrollBusy = false
                    // Another app gesture took precedence: drop queued stale scroll.
                    scrollPending = 0.0
                }
            }, main
        )
        if (!accepted) {
            scrollBusy = false
            scrollPending = 0.0
        }
    }

    private fun startDrag(): JSONObject {
        if (dragActive) return ok()
        if (scrollBusy) return fail("Дождитесь завершения прокрутки")
        dragActive = true
        dragBusy = true
        dragEnding = false
        dragTargetX = cursorX
        dragTargetY = cursorY
        dragStrokeX = cursorX
        dragStrokeY = cursorY
        cursorVisible = true
        refreshPointer()
        // The initial stationary segment must exceed the Android long press
        // threshold for drag-and-drop to work in ordinary launcher apps.
        val path = Path().apply { moveTo(cursorX, cursorY) }
        val first = GestureDescription.StrokeDescription(path, 0, 650L, true)
        val accepted = dispatchGesture(
            GestureDescription.Builder().addStroke(first).build(),
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    if (!dragActive) return
                    dragStroke = first
                    dragBusy = false
                    pumpDrag()
                }
                override fun onCancelled(gestureDescription: GestureDescription?) {
                    resetDrag()
                }
            }, main
        )
        if (!accepted) resetDrag()
        return if (accepted) ok() else fail("Зажатие недоступно на этой приставке")
    }

    private fun moveDrag(dx: Float, dy: Float): JSONObject {
        if (!dragActive) return fail("Сначала удерживайте палец")
        cursorX = (cursorX + dx).coerceIn(1f, (screenWidth - 2).toFloat())
        cursorY = (cursorY + dy).coerceIn(1f, (screenHeight - 2).toFloat())
        cursorVisible = true
        refreshPointer()
        dragTargetX = cursorX
        dragTargetY = cursorY
        pumpDrag()
        return ok()
    }

    private fun finishDrag(): JSONObject {
        if (!dragActive) return ok()
        dragEnding = true
        pumpDrag()
        return ok()
    }

    private fun pumpDrag() {
        if (!dragActive || dragBusy) return
        val previous = dragStroke ?: return
        val finalSegment = dragEnding
        if (!finalSegment && abs(dragTargetX - dragStrokeX) < .5f &&
            abs(dragTargetY - dragStrokeY) < .5f) return
        val targetX = dragTargetX
        val targetY = dragTargetY
        val path = Path().apply {
            moveTo(dragStrokeX, dragStrokeY)
            lineTo(targetX, targetY)
        }
        val next = previous.continueStroke(path, 0, 50L, !finalSegment)
        dragBusy = true
        val accepted = dispatchGesture(
            GestureDescription.Builder().addStroke(next).build(),
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    if (!dragActive) return
                    dragStrokeX = targetX
                    dragStrokeY = targetY
                    dragBusy = false
                    if (finalSegment) resetDrag() else {
                        dragStroke = next
                        pumpDrag()
                    }
                }
                override fun onCancelled(gestureDescription: GestureDescription?) {
                    resetDrag()
                }
            }, main
        )
        if (!accepted) resetDrag()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        installCursor()
        server?.stop()
        server = CompanionServer(applicationContext, this).also { it.start() }
    }

    override fun onDestroy() {
        server?.stop()
        server = null
        resetDrag()
        if (pointer != null) {
            try { manager?.removeView(pointer) } catch (_: Exception) {}
        }
        pointer = null
        if (instance === this) instance = null
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun installCursor() {
        manager = getSystemService(WINDOW_SERVICE) as WindowManager
        val size = Point()
        manager!!.defaultDisplay.getRealSize(size)
        screenWidth = size.x.coerceAtLeast(1)
        screenHeight = size.y.coerceAtLeast(1)
        cursorX = screenWidth / 2f
        cursorY = screenHeight / 2f
        val cursorSize = (50 * resources.displayMetrics.density).roundToInt().coerceAtLeast(50)
        val p = WindowManager.LayoutParams(
            cursorSize, cursorSize,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        )
        p.gravity = Gravity.TOP or Gravity.START
        params = p
        pointer = CursorView().apply { visibility = View.INVISIBLE }
        try {
            manager!!.addView(pointer, p)
            refreshPointer()
        } catch (_: Exception) {
            pointer = null
        }
    }

    private fun refreshPointer() {
        val view = pointer ?: return
        val p = params ?: return
        p.x = (cursorX - p.width * .28f).roundToInt()
        p.y = (cursorY - p.height * .23f).roundToInt()
        view.visibility = if (cursorVisible) View.VISIBLE else View.INVISIBLE
        try { manager?.updateViewLayout(view, p) } catch (_: Exception) {}
    }

    fun showTestCursor() {
        cursorVisible = true
        cursorX = screenWidth / 2f
        cursorY = screenHeight / 2f
        refreshPointer()
    }

    /** Called only on main thread after CompanionServer authenticates session. */
    fun handle(req: JSONObject): JSONObject {
        return when (req.optString("cmd")) {
            "move" -> {
                val dx = req.optDouble("dx", 0.0).coerceIn(-250.0, 250.0).toFloat()
                val dy = req.optDouble("dy", 0.0).coerceIn(-250.0, 250.0).toFloat()
                cursorX = (cursorX + dx).coerceIn(1f, (screenWidth - 2).toFloat())
                cursorY = (cursorY + dy).coerceIn(1f, (screenHeight - 2).toFloat())
                cursorVisible = true
                refreshPointer()
                ok()
            }
            "screen_tap" -> {
                val x = normalized(req, "x", screenWidth)
                val y = normalized(req, "y", screenHeight)
                if (gesture(x, y, x, y, 60L)) ok() else fail("Не удалось нажать на экран")
            }
            "screen_long" -> {
                val x = normalized(req, "x", screenWidth)
                val y = normalized(req, "y", screenHeight)
                if (gesture(x, y, x, y, 750L)) ok() else fail("Долгое нажатие недоступно")
            }
            "screen_scroll" -> {
                val x = normalized(req, "x", screenWidth)
                val y = normalized(req, "y", screenHeight)
                val direction = req.optInt("dy", 1)
                if (scrollNodeAt(x, y, direction > 0)) ok()
                else {
                    cursorX = x
                    cursorY = y
                    enqueueScroll(if (direction > 0) 1.0 else -1.0)
                }
            }
            "screen_swipe" -> {
                val x1 = normalized(req, "x1", screenWidth)
                val y1 = normalized(req, "y1", screenHeight)
                val x2 = normalized(req, "x2", screenWidth)
                val y2 = normalized(req, "y2", screenHeight)
                val duration = req.optLong("duration", 280L).coerceIn(100L, 900L)
                // Android TV lists sometimes ignore touchscreen swipes, but expose
                // Accessibility ACTION_SCROLL_FORWARD/BACKWARD. Prefer that for
                // predominantly vertical gestures, falling back to a real swipe.
                val vertical = abs(y2 - y1) > abs(x2 - x1) * 1.5f &&
                    abs(y2 - y1) > 35f
                val scrolled = vertical && scrollNodeAt(x1, y1, y2 < y1)
                if (scrolled || gesture(x1, y1, x2, y2, duration)) ok()
                else fail("Не удалось выполнить жест")
            }
            "drag_start" -> startDrag()
            "drag_move" -> {
                val dx = req.optDouble("dx", 0.0).coerceIn(-250.0, 250.0).toFloat()
                val dy = req.optDouble("dy", 0.0).coerceIn(-250.0, 250.0).toFloat()
                moveDrag(dx, dy)
            }
            "drag_end" -> finishDrag()
            "tap" -> {
                cursorVisible = true
                refreshPointer()
                if (gesture(cursorX, cursorY, cursorX, cursorY, 55L)) ok()
                else fail("Жест недоступен на этой прошивке")
            }
            "long_press" -> {
                cursorVisible = true
                refreshPointer()
                if (gesture(cursorX, cursorY, cursorX, cursorY, 650L)) ok()
                else fail("Долгое нажатие недоступно")
            }
            "scroll" -> {
                val direction = req.optDouble("dy", 1.0).coerceIn(-4.0, 4.0)
                if (direction == 0.0) ok() else enqueueScroll(direction)
            }
            "text" -> {
                val text = req.optString("text", "")
                if (text.isEmpty() || text.length > 4000) fail("Введите текст до 4000 символов")
                else if (TvInputMethodService.instance?.commit(text) == true) ok()
                else if (appendToFocusedField(text)) ok()
                else fail("Нет активного поля. Включите клавиатуру «Пульт · ввод с телефона» на приставке")
            }
            "delete" -> {
                if (TvInputMethodService.instance?.delete() == true || removeLastFromFocusedField()) ok()
                else fail("Нет активного текстового поля")
            }
            "key" -> key(req.optInt("code", -1))
            "hide_cursor" -> {
                cursorVisible = false
                refreshPointer()
                ok()
            }
            else -> fail("Неизвестная команда")
        }
    }

    private fun scrollNodeAt(x: Float, y: Float, forward: Boolean): Boolean {
        val root = rootInActiveWindow ?: return false
        val action = if (forward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                     else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        val queue = java.util.ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        var count = 0
        var result = false
        try {
            while (queue.isNotEmpty() && count++ < 180) {
                val node = queue.removeFirst()
                val bounds = Rect()
                node.getBoundsInScreen(bounds)
                if (bounds.contains(x.toInt(), y.toInt())) {
                    if (node.isScrollable && node.performAction(action)) {
                        result = true
                        node.recycle()
                        break
                    }
                    for (i in 0 until node.childCount) {
                        node.getChild(i)?.let { queue.add(it) }
                    }
                }
                node.recycle()
            }
        } catch (_: Exception) { /* Some vendor accessibility trees are incomplete. */
        } finally {
            while (queue.isNotEmpty()) queue.removeFirst().recycle()
        }
        return result
    }

    // The phone sends fractions of the captured image, NOT raw phone pixels.
    private fun normalized(req: JSONObject, key: String, dimension: Int): Float {
        val value = req.optDouble(key, 0.5).let { if (it.isFinite()) it else 0.5 }
        return (value.coerceIn(0.0, 1.0) * (dimension - 1)).toFloat()
    }

    private fun gesture(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long): Boolean {
        val path = Path().apply {
            moveTo(x1, y1)
            if (x1 != x2 || y1 != y2) lineTo(x2, y2)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
        return dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, main)
    }

    private fun focusedEditable(): AccessibilityNodeInfo? {
        // Only the focused editable node. Never inspect or transmit the screen contents.
        val node = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        return node?.takeIf { it.isEditable }
    }

    private fun appendToFocusedField(value: String): Boolean {
        val node = focusedEditable() ?: return false
        return try {
            if (node.isPassword) return false // Only trusted IME can edit password fields.
            val existing = node.text?.toString() ?: ""
            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, existing + value)
            })
        } finally { node.recycle() }
    }

    private fun removeLastFromFocusedField(): Boolean {
        val node = focusedEditable() ?: return false
        return try {
            if (node.isPassword) return false
            val existing = node.text?.toString() ?: return false
            if (existing.isEmpty()) return false
            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    existing.dropLast(1))
            })
        } finally { node.recycle() }
    }

    /** Accessibility focus navigation for web D-pad where applications expose a focus tree.
     * Some TV games/custom launchers require native key injection, which Accessibility
     * cannot provide; they remain controllable by cursor and direct screen gestures.
     */
    private fun accessibilityDpad(code: Int): JSONObject {
        val root = rootInActiveWindow ?: return fail("Приложение не поддерживает навигацию")
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
        try {
            if (code == KeyEvent.KEYCODE_DPAD_CENTER) {
                val target = focused ?: root
                return if (target.performAction(AccessibilityNodeInfo.ACTION_CLICK)) ok()
                    else if (gesture(cursorX, cursorY, cursorX, cursorY, 60L)) ok()
                    else fail("Не удалось нажать ОК")
            }
            val direction = when (code) {
                KeyEvent.KEYCODE_DPAD_UP -> View.FOCUS_UP
                KeyEvent.KEYCODE_DPAD_DOWN -> View.FOCUS_DOWN
                KeyEvent.KEYCODE_DPAD_LEFT -> View.FOCUS_LEFT
                KeyEvent.KEYCODE_DPAD_RIGHT -> View.FOCUS_RIGHT
                else -> return fail("Неизвестное направление")
            }
            val next = (focused ?: root).focusSearch(direction)
                ?: return fail("Для этого приложения используйте мышь")
            return try {
                if (next.performAction(AccessibilityNodeInfo.ACTION_FOCUS) ||
                    next.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)) ok()
                else fail("Для этого приложения используйте мышь")
            } finally { next.recycle() }
        } finally {
            focused?.recycle()
            if (root !== focused) root.recycle()
        }
    }

    private fun key(code: Int): JSONObject {
        if (code in listOf(KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN,
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
                KeyEvent.KEYCODE_DPAD_CENTER)) return accessibilityDpad(code)
        val action = when (code) {
            KeyEvent.KEYCODE_BACK -> GLOBAL_ACTION_BACK
            KeyEvent.KEYCODE_HOME -> GLOBAL_ACTION_HOME
            KeyEvent.KEYCODE_APP_SWITCH -> GLOBAL_ACTION_RECENTS
            else -> null
        }
        if (action != null) return if (performGlobalAction(action)) ok() else fail("Команда недоступна")
        if (code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN ||
            code == KeyEvent.KEYCODE_VOLUME_MUTE) {
            val audio = getSystemService(AUDIO_SERVICE) as AudioManager
            val direction = when (code) {
                KeyEvent.KEYCODE_VOLUME_UP -> AudioManager.ADJUST_RAISE
                KeyEvent.KEYCODE_VOLUME_DOWN -> AudioManager.ADJUST_LOWER
                else -> AudioManager.ADJUST_TOGGLE_MUTE
            }
            audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, 0)
            return ok()
        }
        if (code in listOf(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_NEXT,
                KeyEvent.KEYCODE_MEDIA_PREVIOUS)) {
            val audio = getSystemService(AUDIO_SERVICE) as AudioManager
            val now = android.os.SystemClock.uptimeMillis()
            audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
            audio.dispatchMediaKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, code, 0))
            return ok()
        }
        return fail("Эту кнопку отправляйте через штатный Android TV Remote")
    }

    private fun ok() = JSONObject().put("ok", true)
    private fun fail(message: String) = JSONObject().put("ok", false).put("error", message)

    private inner class CursorView : View(this@TvAccessibilityService) {
        private val outline = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.BLACK; style = Paint.Style.STROKE; strokeWidth = 5f
        }
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(45, 199, 255); style = Paint.Style.FILL
        }
        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val s = width / 50f
            canvas.save()
            canvas.scale(s, s)
            val path = Path().apply {
                moveTo(6f, 5f); lineTo(7f, 35f); lineTo(16f, 27f)
                lineTo(23f, 41f); lineTo(31f, 37f); lineTo(23f, 24f)
                lineTo(36f, 22f); close()
            }
            canvas.drawPath(path, outline)
            canvas.drawPath(path, fill)
            canvas.restore()
        }
    }
}
