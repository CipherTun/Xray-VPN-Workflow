package io.surprise.vpn

import android.net.VpnService
import io.surprise.mobile.Mobile
import io.surprise.mobile.Protector
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

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
        installProtector()
    }

    /**
     * Installs the socket protector. Needed before anything that opens a connection while no VPN service is
     * attached (latency tests, host key probes), because the Go side keeps one global protector and would
     * otherwise have none.
     */
    @Synchronized
    fun installProtector() {
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

    /**
     * Hands the downloaded routing lists to the library with one rule rebuild.
     * [files] maps a list name (`geoip:cn`, `geosite:cn`, ...) to a file name inside [dir]; each file holds one
     * domain or CIDR per line. A missing or unreadable file is skipped and reported. Returns a message or null.
     */
    fun setRouteLists(dir: File, files: JSONObject): String? {
        val problems = mutableListOf<String>()
        val all = JSONObject()
        for (name in files.keys()) {
            val f = File(dir, files.optString(name))
            // Never read outside the list folder, whatever Dart sent.
            if (f.parentFile?.canonicalPath != dir.canonicalPath || !f.isFile) {
                problems += "$name: file missing"
                continue
            }
            try {
                val arr = JSONArray()
                f.forEachLine { l ->
                    val t = l.trim()
                    if (t.isNotEmpty() && !t.startsWith("#")) arr.put(t)
                }
                all.put(name, arr)
            } catch (e: Exception) {
                problems += "$name: ${e.message}"
            }
        }
        if (all.length() > 0) {
            try {
                Mobile.setRouteLists(all.toString())
            } catch (t: Throwable) {
                problems += (t.message ?: "the library refused the lists")
            }
        }
        return if (problems.isEmpty()) null else problems.joinToString("; ")
    }

    fun up(): Long = try { Mobile.trafficUp() } catch (_: Throwable) { 0L }
    fun down(): Long = try { Mobile.trafficDown() } catch (_: Throwable) { 0L }
    fun resetTraffic() { try { Mobile.resetTraffic() } catch (_: Throwable) {} }

    /** Share link -> v2tun JSON config (with the display name under "name"). Throws on a bad link. */
    fun parseLink(link: String): String = Mobile.parseLink(link)

    /** Latency in ms through the given config. Throws on failure. */
    fun ping(configJson: String, url: String): Long = Mobile.ping(configJson, url)

    /**
     * Connects to the SSH server in the config (through its payload / TLS / WebSocket chain), does the key
     * exchange and returns the host key fingerprint ("SHA256:...") without logging in. Throws on failure.
     */
    fun probeHostKey(configJson: String, timeoutSec: Int): String {
        installProtector()
        return Mobile.probeHostKey(configJson, timeoutSec.toLong())
    }

    /** Checks a payload template. Returns an error text or null when it compiles. */
    fun validatePayload(template: String): String? = try {
        Mobile.validatePayload(template)
        null
    } catch (t: Throwable) {
        t.message ?: "invalid payload"
    }

    /** Renders a payload with visible \r\n and split markers. Throws when it does not compile. */
    fun previewPayload(template: String, host: String, port: Int): String = Mobile.previewPayload(template, host, port.toLong())

    /** Built-in payload presets, one name per line. */
    fun payloadPresets(): String = try { Mobile.payloadPresets() } catch (_: Throwable) { "" }

    /** How the running tunnel would route a connection, as JSON {"action":..,"rule":..}. Throws when not running. */
    fun explainRoute(network: String, addr: String, protocol: String): String = Mobile.explainRoute(network, addr, protocol)

    /** Swaps the routing section while connected. Returns an error text or null. */
    fun updateRouting(routingJson: String): String? = try {
        Mobile.updateRouting(routingJson)
        null
    } catch (t: Throwable) {
        t.message ?: "routing update failed"
    }
}
