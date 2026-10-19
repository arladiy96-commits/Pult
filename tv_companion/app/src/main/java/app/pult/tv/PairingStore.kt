package app.pult.tv

import android.content.Context
import android.util.Base64
import java.security.SecureRandom

/** Device-local trust store: pairing only when TV user explicitly opens a short window. */
class PairingStore(context: Context) {
    private val prefs = context.getSharedPreferences("companion_pairing_v1", Context.MODE_PRIVATE)
    private val random = SecureRandom()
    private var pin: String? = null
    private var expiresAt = 0L
    private var failed = 0
    private var blockedUntil = 0L

    @Synchronized fun openWindow(): String {
        val newPin = (random.nextInt(900000) + 100000).toString()
        pin = newPin
        expiresAt = System.currentTimeMillis() + 120_000L
        failed = 0
        return newPin
    }

    @Synchronized fun visiblePin(): String? = if (System.currentTimeMillis() < expiresAt) pin else null
    @Synchronized fun remainingSeconds(): Long = if (visiblePin() == null) 0 else
        ((expiresAt - System.currentTimeMillis()) / 1000).coerceAtLeast(0)

    @Synchronized fun pair(candidate: String): String? {
        val now = System.currentTimeMillis()
        if (now < blockedUntil || visiblePin() == null) return null
        if (candidate != pin) {
            failed++
            if (failed >= 5) {
                blockedUntil = now + 60_000L
                pin = null
            }
            return null
        }
        pin = null
        expiresAt = 0
        failed = 0
        val token = token()
        prefs.edit().putString("trusted_token", token).apply()
        return token
    }

    /** Web logins do not rotate the Android app's existing trusted token. */
    @Synchronized fun consumeWebPin(candidate: String): Boolean {
        val now = System.currentTimeMillis()
        if (now < blockedUntil || visiblePin() == null) return false
        if (candidate != pin) {
            failed++
            if (failed >= 5) {
                blockedUntil = now + 60_000L
                pin = null
            }
            return false
        }
        pin = null
        expiresAt = 0
        failed = 0
        return true
    }

    @Synchronized fun webRevocationVersion(): Long = prefs.getLong("web_revoked_at", 0L)

    @Synchronized fun authenticated(input: String): Boolean {
        val existing = prefs.getString("trusted_token", null) ?: return false
        // Constant-time comparison for equal-length secrets.
        return java.security.MessageDigest.isEqual(existing.toByteArray(), input.toByteArray())
    }

    @Synchronized fun revoke() {
        prefs.edit().remove("trusted_token")
            .putLong("web_revoked_at", System.currentTimeMillis()).apply()
        pin = null
        expiresAt = 0
    }

    @Synchronized fun hasTrustedPhone(): Boolean = prefs.contains("trusted_token")

    private fun token(): String {
        val bytes = ByteArray(32)
        random.nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.URL_SAFE)
    }
}
