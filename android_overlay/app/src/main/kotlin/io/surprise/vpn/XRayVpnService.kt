package io.surprise.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.TrafficStats
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * TUN-mode VPN. The service creates the TUN interface with VpnService.Builder and hands
 * its file descriptor to Xray-core, whose native `tun` inbound reads and writes packets.
 *
 * Loop prevention: XRay's own package is always excluded from the VPN
 * (addDisallowedApplication), so Xray's outbound sockets and the SSH session
 * reach the network directly instead of re-entering the tunnel.
 *
 * Staying alive (wake mode "strong"):
 *  - foreground service with an ongoing notification, START_STICKY, Always-on VPN support
 *  - PARTIAL_WAKE_LOCK (CPU) re-armed every 25 s by a watchdog
 *  - Wi-Fi lock (low-latency on Android 10+, high-perf before) so Wi-Fi does not nap with the screen off
 *  - network callback logging switches between Wi-Fi and mobile data
 *  - watchdog verifying the TUN descriptor is still valid
 *  - optional start on boot
 */
class XRayVpnService : VpnService() {

    companion object {
        const val ACTION_START = "io.surprise.vpn.START"
        const val ACTION_STOP = "io.surprise.vpn.STOP"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_OPTS = "opts"
        private const val CHANNEL = "xray_vpn_status"
        private const val NOTIF_ID = 1
        private const val LOCK_MS = 30 * 60 * 1000L
        @Volatile var running = false

        fun prefs(c: Context) = c.getSharedPreferences("xray_native", Context.MODE_PRIVATE)

        fun startIntent(c: Context, config: String, opts: String) =
            Intent(c, XRayVpnService::class.java).setAction(ACTION_START)
                .putExtra(EXTRA_CONFIG, config).putExtra(EXTRA_OPTS, opts)

        fun stopIntent(c: Context) = Intent(c, XRayVpnService::class.java).setAction(ACTION_STOP)
    }

    private var tun: ParcelFileDescriptor? = null
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var statsOn = false
    @Volatile private var watchdogOn = false
    @Volatile private var killSwitch = false
    private var name = "XRay"
    private var wakeMode = "strong"
    @Volatile private var useUnderlying = true
    private var hideOnLock = true
    private var cpuLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var netCb: ConnectivityManager.NetworkCallback? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            worker.execute { stopTunnel("disconnected") }
            return START_NOT_STICKY
        }
        // START, or a null intent when the system restarts us (Always-on VPN / process death).
        val p = prefs(this)
        val cfg = intent?.getStringExtra(EXTRA_CONFIG) ?: p.getString(EXTRA_CONFIG, null)
        val opts = intent?.getStringExtra(EXTRA_OPTS) ?: p.getString(EXTRA_OPTS, "{}") ?: "{}"
        if (cfg == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val o = JSONObject(opts)
        p.edit().putString(EXTRA_CONFIG, cfg).putString(EXTRA_OPTS, opts)
            .putBoolean("bootStart", o.optBoolean("bootStart")).apply()
        name = if (o.optBoolean("notifShowServer", true)) o.optString("name", "XRay") else "XRay"
        useUnderlying = o.optBoolean("useUnderlying", true)
        hideOnLock = o.optBoolean("notifHideLock", true)
        wakeMode = o.optString("wakeMode", "strong")
        startForegroundCompat(buildNotification("Connecting…"))
        worker.execute { startTunnel(cfg, o) }
        return START_STICKY
    }

    // ───────── tunnel lifecycle ─────────

    private fun startTunnel(cfgJson: String, o: JSONObject) {
        VpnEvents.status("connecting")
        try {
            XrayCore.stop()
            closeTun()
            killSwitch = o.optBoolean("killSwitch")

            val b = Builder()
                .setSession("XRay VPN")
                .setMtu(o.optInt("mtu", 1500))
                .addAddress("172.19.0.1", 30)
                .addRoute("0.0.0.0", 0)
            if (o.optBoolean("ipv6")) {
                b.addAddress("fd00:1:fd00:1::1", 126)
                b.addRoute("::", 0)
            }

            val dns = o.optJSONArray("dns")
            var added = 0
            if (dns != null) for (i in 0 until dns.length()) {
                val d = dns.optString(i)
                if (d.isNotBlank()) { try { b.addDnsServer(d); added++ } catch (_: Exception) {} }
            }
            if (added == 0) b.addDnsServer("1.1.1.1")
            if (Build.VERSION.SDK_INT >= 29) b.setMetered(false)
            if (o.optBoolean("allowBypass")) b.allowBypass()
            if (Build.VERSION.SDK_INT >= 33 && o.optBoolean("excludeLan")) {
                // Keep LAN, hotspot and casting traffic outside the tunnel.
                for ((addr, len) in listOf("10.0.0.0" to 8, "172.16.0.0" to 12, "192.168.0.0" to 16, "169.254.0.0" to 16)) {
                    try { b.excludeRoute(android.net.IpPrefix(java.net.InetAddress.getByName(addr), len)) } catch (_: Exception) {}
                }
            }

            // Per-app VPN
            val apps = mutableListOf<String>()
            o.optJSONArray("perApps")?.let { a -> for (i in 0 until a.length()) apps.add(a.optString(i)) }
            val mode = o.optString("perAppMode", "off")
            if (mode == "only" && apps.isNotEmpty()) {
                apps.filter { it != packageName }.forEach { try { b.addAllowedApplication(it) } catch (_: Exception) {} }
            } else {
                b.addDisallowedApplication(packageName)
                if (mode == "exclude") apps.forEach { try { b.addDisallowedApplication(it) } catch (_: Exception) {} }
            }

            val pfd = b.establish() ?: throw IllegalStateException("The system refused to create the VPN interface. Is another VPN active?")
            tun = pfd

            copyGeoAssets()
            val cfgFile = File(filesDir, "config.json")
            cfgFile.writeText(cfgJson)
            val err = XrayCore.start(cfgFile.absolutePath, filesDir.absolutePath, pfd.fd)
            cfgFile.delete() // keep keys off disk once the core has read them
            if (err != null) throw IllegalStateException(err)

            running = true
            acquireLocks()
            watchNetworks()
            VpnEvents.status("connected")
            updateNotification("Connected · $name")
            startStats()
            startWatchdog()
        } catch (t: Throwable) {
            VpnEvents.log("error", t.message ?: t.toString())
            failTunnel(t.message ?: "Could not start the tunnel")
        }
    }

    private fun failTunnel(msg: String) {
        statsOn = false
        watchdogOn = false
        running = false
        try { XrayCore.stop() } catch (_: Throwable) {}
        if (killSwitch && tun != null) {
            // Kill switch: keep the TUN interface up with nothing reading it, so traffic is dropped, not leaked.
            VpnEvents.status("error", "$msg Kill switch is blocking traffic until you disconnect.")
            updateNotification("Blocked · tunnel down")
        } else {
            releaseLocks()
            unwatchNetworks()
            closeTun()
            VpnEvents.status("error", msg)
            stopForegroundCompat()
            stopSelf()
        }
    }

    private fun stopTunnel(finalState: String) {
        statsOn = false
        watchdogOn = false
        running = false
        try { XrayCore.stop() } catch (_: Throwable) {}
        releaseLocks()
        unwatchNetworks()
        closeTun()
        VpnEvents.status(finalState)
        stopForegroundCompat()
        stopSelf()
    }

    private fun closeTun() {
        try { tun?.close() } catch (_: Exception) {}
        tun = null
    }

    override fun onRevoke() {
        worker.execute { stopTunnel("revoked") }
    }

    override fun onDestroy() {
        statsOn = false
        watchdogOn = false
        try { XrayCore.stop() } catch (_: Throwable) {}
        releaseLocks()
        unwatchNetworks()
        closeTun()
        running = false
        worker.shutdown()
        super.onDestroy()
    }

    // ───────── wake locks, watchdog, networks ─────────

    private fun acquireLocks() {
        releaseLocks()
        if (wakeMode == "off") return
        val pm = getSystemService(PowerManager::class.java)
        cpuLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "xrayvpn:core").apply {
            setReferenceCounted(false)
            acquire(LOCK_MS) // renewed by the watchdog; never held forever if we crash
        }
        if (wakeMode == "strong") {
            try {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                else @Suppress("DEPRECATION") WifiManager.WIFI_MODE_FULL_HIGH_PERF
                wifiLock = wm.createWifiLock(mode, "xrayvpn:wifi").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (e: Exception) {
                VpnEvents.log("warn", "Wi-Fi lock unavailable: ${e.message}")
            }
        }
        VpnEvents.log("info", "Wake lock: $wakeMode")
    }

    private fun releaseLocks() {
        try { cpuLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        try { wifiLock?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        cpuLock = null
        wifiLock = null
    }

    /** Re-arms the CPU lock and checks that the TUN descriptor is still valid. */
    private fun startWatchdog() {
        watchdogOn = true
        Thread {
            while (watchdogOn) {
                try { Thread.sleep(25_000) } catch (_: InterruptedException) { break }
                if (!watchdogOn) break
                try { cpuLock?.acquire(LOCK_MS) } catch (_: Exception) {}
                val alive = tun?.fileDescriptor?.valid() == true
                if (running && !alive) {
                    VpnEvents.log("error", "Watchdog: the TUN interface went away")
                    worker.execute { failTunnel("The VPN interface was closed by the system.") }
                    break
                }
            }
        }.apply { isDaemon = true; name = "xray-watchdog" }.start()
    }

    private fun watchNetworks() {
        unwatchNetworks()
        try {
            val cm = getSystemService(ConnectivityManager::class.java)
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) { VpnEvents.log("info", "Network available"); refreshUnderlying() }
                override fun onLost(network: Network) { VpnEvents.log("warn", "Network lost, waiting for another one"); refreshUnderlying() }
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { refreshUnderlying() }
            }
            val req = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            cm.registerNetworkCallback(req, cb)
            netCb = cb
        } catch (_: Exception) {}
    }

    /** Tells Android which real network (Wi-Fi preferred) carries the tunnel, for correct handover and metering. */
    @Suppress("DEPRECATION")
    private fun refreshUnderlying() {
        if (!useUnderlying || !running) return
        try {
            val cm = getSystemService(ConnectivityManager::class.java)
            val nets = cm.allNetworks.filter { n ->
                val c = cm.getNetworkCapabilities(n)
                c != null && c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    !c.hasTransport(NetworkCapabilities.TRANSPORT_VPN) && c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            }
            val best = nets.firstOrNull { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true } ?: nets.firstOrNull()
            setUnderlyingNetworks(if (best != null) arrayOf(best) else null)
        } catch (_: Exception) {}
    }

    private fun unwatchNetworks() {
        try { netCb?.let { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) } } catch (_: Exception) {}
        netCb = null
    }

    // ───────── helpers ─────────

    /** geoip.dat / geosite.dat shipped in assets (see scripts/build_cores.sh) are copied next to the config. */
    private fun copyGeoAssets() {
        for (n in listOf("geoip.dat", "geosite.dat")) {
            val dst = File(filesDir, n)
            if (dst.exists()) continue
            try { assets.open(n).use { i -> dst.outputStream().use { o -> i.copyTo(o) } } } catch (_: Exception) {}
        }
    }

    private fun rate(b: Long): String {
        val u = arrayOf("B/s", "KB/s", "MB/s", "GB/s")
        var v = b.toDouble(); var i = 0
        while (v >= 1024 && i < u.size - 1) { v /= 1024; i++ }
        return String.format("%.1f %s", v, u[i])
    }

    /** Device-level counters: XRay itself is excluded from the VPN, so these approximate tunnel traffic. */
    private fun startStats() {
        statsOn = true
        Thread {
            val rx0 = TrafficStats.getTotalRxBytes()
            val tx0 = TrafficStats.getTotalTxBytes()
            var lastRx = rx0
            var lastTx = tx0
            var tick = 0
            while (statsOn) {
                try { Thread.sleep(1000) } catch (_: InterruptedException) { break }
                val rx = TrafficStats.getTotalRxBytes()
                val tx = TrafficStats.getTotalTxBytes()
                if (rx == TrafficStats.UNSUPPORTED.toLong()) break
                VpnEvents.stats(rx - rx0, tx - tx0, rx - lastRx, tx - lastTx)
                if (++tick % 3 == 0) updateNotification("↓ ${rate((rx - lastRx))}  ↑ ${rate((tx - lastTx))} · $name")
                lastRx = rx
                lastTx = tx
            }
        }.apply { isDaemon = true; name = "xray-stats" }.start()
    }

    private fun buildNotification(text: String): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "VPN status", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stop = PendingIntent.getService(this, 1, stopIntent(this), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        b.setSmallIcon(R.drawable.ic_stat_shield)
            .setContentTitle("XRay VPN")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "Disconnect", stop).build())
        if (hideOnLock) {
            // Lock screen shows only that the VPN is on; details need an unlocked phone.
            val pub = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this))
                .setSmallIcon(R.drawable.ic_stat_shield).setContentTitle("XRay VPN").setContentText("VPN is on").build()
            b.setVisibility(Notification.VISIBILITY_PRIVATE).setPublicVersion(pub)
        }
        if (Build.VERSION.SDK_INT >= 31) b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        return b.build()
    }

    private fun startForegroundCompat(n: Notification) {
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIF_ID, n, 0x400 /* FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED */)
        else startForeground(NOTIF_ID, n)
    }

    private fun updateNotification(text: String) {
        try { getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(text)) } catch (_: Exception) {}
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
    }
}
