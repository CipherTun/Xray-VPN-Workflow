package io.surprise.vpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle

/** Invisible trampoline for launcher shortcuts: connects with the last used server, or disconnects. */
class ShortcutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent?.action) {
            "io.surprise.vpn.DISCONNECT" -> startService(XRayVpnService.stopIntent(this))
            else -> {
                val p = XRayVpnService.prefs(this)
                val cfg = p.getString(XRayVpnService.EXTRA_CONFIG, null)
                if (cfg == null || VpnService.prepare(this) != null) {
                    // Nothing saved yet or consent needed: open the app instead.
                    startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } else {
                    val i = XRayVpnService.startIntent(this, cfg, p.getString(XRayVpnService.EXTRA_OPTS, "{}") ?: "{}")
                    if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                }
            }
        }
        finish()
    }
}
