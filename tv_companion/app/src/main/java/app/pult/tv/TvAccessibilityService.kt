package app.pult.tv

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Canvas
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
                if (direction == 0.0) ok() else {
                    val travel = (100f * kotlin.math.abs(direction).toFloat()).coerceAtMost(screenHeight * .45f)
                    val safeX = cursorX.coerceIn(12f, (screenWidth - 12).toFloat())
                    val midY = cursorY.coerceIn(screenHeight * .3f, screenHeight * .7f)
                    // Positive dy means scroll content DOWN (finger swipes UP).
                    val startY = midY + if (direction > 0) travel / 2 else -travel / 2
                    val endY = midY + if (direction > 0) -travel / 2 else travel / 2
                    if (gesture(safeX, startY, safeX, endY, 260L)) ok()
                    else fail("Прокрутка недоступна")
                }
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

    private fun key(code: Int): JSONObject {
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
