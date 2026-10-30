package io.surprise.vpn

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Bridges native VPN state and logs to Dart over an EventChannel. */
object VpnEvents {
    @Volatile var sink: EventChannel.EventSink? = null
    @Volatile var state: String = "disconnected"
    private val main = Handler(Looper.getMainLooper())

    fun status(s: String, msg: String? = null) {
        if (s != "revoked") state = if (s == "error") "disconnected" else s
        emit(mapOf("type" to "status", "state" to s, "message" to msg))
    }

    fun importText(text: String) = emit(mapOf("type" to "import", "text" to text))

    fun log(level: String, msg: String) = emit(mapOf("type" to "log", "level" to level, "msg" to msg))

    fun stats(rx: Long, tx: Long, rxBps: Long, txBps: Long) =
        emit(mapOf("type" to "stats", "rx" to rx, "tx" to tx, "rxBps" to rxBps, "txBps" to txBps))

    private fun emit(m: Map<String, Any?>) {
        main.post { sink?.success(m) }
    }
}
