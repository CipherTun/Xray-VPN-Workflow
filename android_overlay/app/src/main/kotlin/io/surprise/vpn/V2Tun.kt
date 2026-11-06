package io.surprise.vpn

import android.net.VpnService
import io.surprise.mobile.Mobile
import io.surprise.mobile.Protector

/**
 * Thin wrapper over v2tun.aar (CipherTun/V2-TUN, gomobile package io.surprise.mobile).
 *
 * Loop prevention: the library protects every socket it opens to the server through [Protector],
 * so the app itself is NOT excluded from the VPN. The Go side keeps one global protector, so a
 * delegating object is installed once and pointed at the running service.
 */
object V2Tun {
    @Volatile private var svc: VpnService? = null
    private var installed = false

    private val protector = object : Protector {
        // No VPN service (not connected yet, e.g. a latency test): nothing to protect, allow the socket.
        override fun protect(fd: Long): Boolean = svc?.protect(fd.toInt()) ?: true
    }

    @Synchronized
    fun attach(s: VpnService) {
        svc = s
        if (!installed) {
            Mobile.setProtector(protector)
            installed = true
        }
    }

    fun detach(s: VpnService) {
        if (svc === s) svc = null
    }

    /** Starts the TUN stack on [fd] (ownership of the descriptor passes to the library). Returns an error text or null. */
    @Synchronized
    fun start(configJson: String, fd: Int, mtu: Int, dns: String, fakeDns: Boolean, sniff: Boolean): String? = try {
        Mobile.startTunEx(configJson, fd.toLong(), mtu.toLong(), dns, fakeDns, sniff)
        null
    } catch (t: Throwable) {
        t.message?.takeIf { it.isNotBlank() } ?: "The tunnel library failed to start"
    }

    @Synchronized
    fun stop() {
        try { Mobile.stopTun() } catch (_: Throwable) {}
    }

    /** Fills a `list:NAME` routing list (one domain or CIDR per line). Returns an error text or null. */
    fun setRouteList(name: String, items: String): String? = try {
        Mobile.setRouteList(name, items)
        null
    } catch (t: Throwable) {
        t.message ?: "route list failed"
    }

    fun up(): Long = try { Mobile.trafficUp() } catch (_: Throwable) { 0L }
    fun down(): Long = try { Mobile.trafficDown() } catch (_: Throwable) { 0L }
    fun resetTraffic() { try { Mobile.resetTraffic() } catch (_: Throwable) {} }

    /** Share link -> v2tun JSON config (with the display name under "name"). Throws on a bad link. */
    fun parseLink(link: String): String = Mobile.parseLink(link)

    /** Latency in ms through the given config. Throws on failure. */
    fun ping(configJson: String, url: String): Long = Mobile.ping(configJson, url)
}
