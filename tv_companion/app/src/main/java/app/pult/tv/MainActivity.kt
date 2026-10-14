package app.pult.tv

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.view.inputmethod.InputMethodManager
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections

/** TV-facing installation, permissions, pairing, and local cursor test screen. */
class MainActivity : Activity() {
    private val bg = Color.rgb(6, 16, 26)
    private val text = Color.rgb(244, 250, 255)
    private val secondary = Color.rgb(142, 167, 186)
    private val cyan = Color.rgb(41, 199, 255)
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var info: TextView
    private lateinit var pinLabel: TextView
    private lateinit var trustLabel: TextView
    private lateinit var pairing: PairingStore
    private var fingerprint: String? = null
    private val refresh = object : Runnable {
        override fun run() {
            updateStatus()
            handler.postDelayed(this, 2000L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pairing = CompanionState.store(applicationContext)
        window.decorView.setBackgroundColor(bg)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(30), dp(20), dp(30), dp(30))
        }
        val scroll = ScrollView(this).apply {
            isFillViewport = false
            addView(root)
        }
        setContentView(scroll)

        root.addView(label("ПУЛЬТ · ПРИСТАВКА", 27f, cyan, true))
        root.addView(label("Служба управления X96 по Wi-Fi · версия 0.1.0", 15f, secondary))
        gap(root, 20)

        info = label("Проверка службы…", 17f, text)
        root.addView(info)
        gap(root, 14)

        action(root, "1. ВКЛЮЧИТЬ УПРАВЛЕНИЕ", "Настройки → Специальные возможности → Пульт · управление приставкой") {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
        action(root, "2. ВКЛЮЧИТЬ КЛАВИАТУРУ", "Настройки → Язык и ввод → Экранная клавиатура → Управление клавиатурами") {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        action(root, "3. ВЫБРАТЬ КЛАВИАТУРУ", "Выберите «Пульт · ввод с телефона» для надёжного русского ввода") {
            (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showInputMethodPicker()
        }
        action(root, "ПОКАЗАТЬ ТЕСТОВЫЙ КУРСОР", "Проверяет видимость курсора поверх этого экрана") {
            val service = TvAccessibilityService.instance
            if (service == null) {
                info.text = "Сначала включите службу специальных возможностей."
            } else {
                service.showTestCursor()
            }
        }

        gap(root, 18)
        root.addView(label("СОПРЯЖЕНИЕ", 21f, cyan, true))
        root.addView(label("Телефон и приставка должны быть в одной локальной сети. Откройте окно сопряжения только когда готовы вводить код.", 14f, secondary))
        gap(root, 7)
        pinLabel = label("Код выключен", 21f, text, true)
        root.addView(pinLabel)
        trustLabel = label("", 13f, secondary)
        root.addView(trustLabel)
        action(root, "ПОКАЗАТЬ КОД НА 2 МИНУТЫ", "Код одноразовый. После сопряжения доступ запоминается на приставке") {
            if (TvAccessibilityService.instance == null) {
                info.text = "Сначала включите службу управления."
            } else {
                pairing.openWindow()
                updateStatus()
            }
        }
        action(root, "СБРОСИТЬ ДОСТУП ТЕЛЕФОНА", "Удаляет сохранённый ключ телефона; затем потребуется новый код") {
            pairing.revoke()
            updateStatus()
        }
        gap(root, 12)
        root.addView(label("Android 13: при блокировке специальных возможностей откройте «О приложении» → ⋮ → «Разрешить ограниченные настройки», затем повторите включение.", 13f, secondary))
        root.addView(label("Соединение защищено TLS. Перед первым сопряжением сравните отпечаток сертификата на телефоне и телевизоре.", 13f, secondary))
    }

    override fun onResume() {
        super.onResume()
        handler.removeCallbacks(refresh)
        handler.post(refresh)
    }

    override fun onPause() {
        handler.removeCallbacks(refresh)
        super.onPause()
    }

    private fun updateStatus() {
        val active = TvAccessibilityService.instance != null
        val ip = localAddresses()
        val fingerprintText = try {
            if (fingerprint == null) fingerprint = SecureTransport.fingerprint()
            fingerprint ?: "Неизвестен"
        } catch (e: Exception) { "Недоступен: ${e.javaClass.simpleName}" }
        info.text = "Служба управления: ${if (active) "ВКЛЮЧЕНА" else "ВЫКЛЮЧЕНА"}\n" +
            "Сервер: ${CompanionServer.status}\n" +
            "IP: $ip    Порт: ${CompanionServer.PORT}\n" +
            "Отпечаток SHA-256:\n$fingerprintText"
        val pin = pairing.visiblePin()
        pinLabel.text = if (pin == null) "Код сопряжения выключен" else
            "КОД: $pin   (${pairing.remainingSeconds()} сек.)"
        trustLabel.text = if (pairing.hasTrustedPhone()) "Телефон сопряжён" else "Нет сопряжённых телефонов"
    }

    private fun localAddresses(): String = try {
        Collections.list(NetworkInterface.getNetworkInterfaces()).asSequence()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { Collections.list(it.inetAddresses).asSequence() }
            .filterIsInstance<Inet4Address>()
            .filter { it.isSiteLocalAddress }
            .map { it.hostAddress ?: "" }
            .distinct().joinToString(" / ").ifEmpty { "Нет локального IPv4" }
    } catch (_: Exception) { "Нет адреса" }

    private fun action(root: LinearLayout, title: String, hint: String, run: () -> Unit) {
        val button = Button(this).apply {
            text = title
            textSize = 15f
            setTextColor(Color.WHITE)
            isAllCaps = false
            setBackgroundTintList(android.content.res.ColorStateList.valueOf(Color.rgb(13, 84, 129)))
            setOnClickListener { run() }
        }
        root.addView(button, LinearLayout.LayoutParams(-1, dp(53)))
        root.addView(label(hint, 12f, secondary))
        gap(root, 9)
    }

    private fun label(value: String, size: Float, color: Int, bold: Boolean = false): TextView =
        TextView(this).apply {
            text = value
            textSize = size
            setTextColor(color)
            gravity = Gravity.START
            if (bold) setTypeface(typeface, Typeface.BOLD)
            setPadding(0, dp(3), 0, dp(5))
        }

    private fun gap(root: LinearLayout, h: Int) {
        root.addView(View(this), LinearLayout.LayoutParams(1, dp(h)))
    }

    private fun dp(pixels: Int): Int = (pixels * resources.displayMetrics.density).toInt()
}
