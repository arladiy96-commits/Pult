package app.pult.tv

import android.graphics.Color
import android.inputmethodservice.InputMethodService
import android.view.Gravity
import android.view.View
import android.view.inputmethod.InputConnection
import android.widget.TextView

/** Optional keyboard: enable AND select it in Android keyboard settings. */
class TvInputMethodService : InputMethodService() {
    companion object {
        @Volatile var instance: TvInputMethodService? = null
            private set
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onCreateInputView(): View {
        return TextView(this).apply {
            text = "ПУЛЬТ · Печатайте с телефона"
            textSize = 17f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.rgb(7, 20, 31))
            gravity = Gravity.CENTER
            setPadding(12, 16, 12, 16)
        }
    }

    fun commit(text: String): Boolean = currentInputConnection?.commitText(text, 1) == true
    fun delete(): Boolean = currentInputConnection?.deleteSurroundingText(1, 0) == true
}
