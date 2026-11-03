package io.surprise.vpn

import android.content.Context
import android.provider.Settings
import android.util.Base64
import go.Seq
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray
import java.security.MessageDigest

/**
 * Thin wrapper over AndroidLibXrayLite (github.com/2dust/AndroidLibXrayLite), the gomobile library
 * that powers v2rayNG. It embeds the full Xray-core, so every protocol and transport Xray knows is
 * available: VLESS, VMess, Trojan, Shadowsocks, SOCKS, HTTP, WireGuard, Hysteria, Reality, XTLS Vision,
 * WebSocket, gRPC, XHTTP, HTTPUpgrade, mKCP and more.
 *
 * The config is passed as text and the TUN file descriptor goes straight into `startLoop`, which feeds
 * Xray's native `tun` inbound, so no config file and no env tricks are needed.
 */
object XrayCore {
    private var appContext: Context? = null
    private var envReady = false
    private var controller: CoreController? = null

    private val callback = object : CoreCallbackHandler {
        override fun startup(): Long = 0
        override fun shutdown(): Long = 0
        override fun onEmitStatus(code: Long, msg: String?): Long {
            if (!msg.isNullOrBlank()) VpnEvents.log("info", msg)
            return 0
        }
    }

    /** Must be called once with a Context before [start] (gomobile needs it for assets and file access). */
    fun attach(ctx: Context) {
        if (appContext != null) return
        appContext = ctx.applicationContext
        Seq.setContext(appContext)
    }

    /** Stable per-install key for XUDP (UDP over a single stream), derived from the device and package. */
    private fun xudpKey(ctx: Context): String {
        val id = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID) ?: "xray"
        val digest = MessageDigest.getInstance("SHA-256").digest("$id|${ctx.packageName}".toByteArray())
        return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    /**
     * Starts Xray with its `tun` inbound bound to [tunFd]. [assetDir] is where geoip.dat / geosite.dat live.
     * Returns an error message, or null on success.
     */
    @Synchronized
    fun start(configJson: String, tunFd: Int, assetDir: String): String? {
        val ctx = appContext ?: return "The core was not attached to the app yet."
        return try {
            if (!envReady) {
                Libv2ray.initCoreEnv(assetDir, xudpKey(ctx))
                envReady = true
            }
            val c = controller ?: Libv2ray.newCoreController(callback).also { controller = it }
            c.startLoop(configJson, tunFd)
            null
        } catch (t: Throwable) {
            t.message?.takeIf { it.isNotBlank() } ?: "Xray failed to start"
        }
    }

    @Synchronized
    fun stop() {
        try {
            controller?.stopLoop()
        } catch (_: Throwable) {
        }
    }

    /** Library and Xray-core version string, for the log. */
    fun version(): String? = try {
        Libv2ray.checkVersionX()
    } catch (_: Throwable) {
        null
    }
}
