package io.surprise.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build

/** Reconnects after a reboot when "Start on boot" is on and VPN permission was already granted. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val act = intent.action
        if (act != Intent.ACTION_BOOT_COMPLETED && act != "android.intent.action.QUICKBOOT_POWERON") return
        val p = XRayVpnService.prefs(context)
        val cfg = p.getString(XRayVpnService.EXTRA_CONFIG, null) ?: return
        if (!p.getBoolean("bootStart", false)) return
        if (VpnService.prepare(context) != null) return // consent not granted, nothing we can do silently
        val i = XRayVpnService.startIntent(context, cfg, p.getString(XRayVpnService.EXTRA_OPTS, "{}") ?: "{}")
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
    }
}
