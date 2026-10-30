package io.surprise.vpn

import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick Settings tile. Reconnects with the last used server. */
class QuickTile : TileService() {

    override fun onStartListening() = refresh()

    override fun onClick() {
        if (XRayVpnService.running) {
            startService(XRayVpnService.stopIntent(this))
        } else {
            val p = XRayVpnService.prefs(this)
            val cfg = p.getString(XRayVpnService.EXTRA_CONFIG, null)
            val needsConsent = VpnService.prepare(this) != null
            if (cfg == null || needsConsent) {
                openApp()
            } else {
                val i = XRayVpnService.startIntent(this, cfg, p.getString(XRayVpnService.EXTRA_OPTS, "{}") ?: "{}")
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
            }
        }
        Handler(Looper.getMainLooper()).postDelayed({ refresh() }, 1200)
    }

    private fun openApp() {
        val i = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION") startActivityAndCollapse(i)
        }
    }

    private fun refresh() {
        val t = qsTile ?: return
        t.state = if (XRayVpnService.running) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        t.label = "XRay VPN"
        if (Build.VERSION.SDK_INT >= 29) t.subtitle = if (XRayVpnService.running) "Connected" else "Off"
        t.updateTile()
    }
}
