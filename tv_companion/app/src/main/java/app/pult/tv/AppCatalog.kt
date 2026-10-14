package app.pult.tv

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/** Query only launchable TV/phone apps; the caller must already be authenticated. */
class AppCatalog(private val context: Context) {
    private val pm = context.packageManager

    fun apps(): JSONArray {
        val seen = mutableSetOf<String>()
        val result = JSONArray()
        for (category in listOf(Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER)) {
            val intent = Intent(Intent.ACTION_MAIN).addCategory(category)
            @Suppress("DEPRECATION")
            val matches = pm.queryIntentActivities(intent, 0)
            for (info in matches.sortedBy { it.loadLabel(pm).toString().lowercase() }) {
                val packageName = info.activityInfo?.packageName ?: continue
                if (!seen.add(packageName) || packageName == context.packageName) continue
                val app = JSONObject().put("name", info.loadLabel(pm).toString())
                    .put("package", packageName)
                try { app.put("icon", iconBase64(info.loadIcon(pm))) } catch (_: Exception) { }
                result.put(app)
                if (result.length() >= 120) return result
            }
        }
        return result
    }

    fun launch(packageName: String): Boolean {
        if (!Regex("^[a-zA-Z0-9_.]{2,200}$").matches(packageName)) return false
        // Whitelist only the app packages actually returned to the launcher catalog.
        if (!canLaunch(packageName)) return false
        val intent = pm.getLeanbackLaunchIntentForPackage(packageName)
            ?: pm.getLaunchIntentForPackage(packageName) ?: return false
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (_: Exception) { false }
    }

    private fun canLaunch(packageName: String): Boolean {
        for (category in listOf(Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER)) {
            @Suppress("DEPRECATION")
            val candidates = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(category), 0)
            if (candidates.any { it.activityInfo?.packageName == packageName }) return true
        }
        return false
    }

    private fun iconBase64(drawable: Drawable): String {
        val size = 48
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        val output = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 80, output)
        bitmap.recycle()
        return Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP)
    }
}
