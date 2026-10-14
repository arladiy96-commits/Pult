package app.pult.tv

import android.content.Context

/** Reuse one pairing window/trust store between Activity and the background service. */
object CompanionState {
    @Volatile private var store: PairingStore? = null
    fun store(context: Context): PairingStore = synchronized(this) {
        store ?: PairingStore(context.applicationContext).also { store = it }
    }
}
