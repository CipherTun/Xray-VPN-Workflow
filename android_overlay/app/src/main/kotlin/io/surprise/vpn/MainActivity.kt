package io.surprise.vpn

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.net.VpnService
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private var pending: MethodChannel.Result? = null

    // VPN consent dialog via the Activity Result API (replaces startActivityForResult).
    private val vpnConsent = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        pending?.success(r.resultCode == RESULT_OK)
        pending = null
    }
    private var initial: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncoming(intent, live = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncoming(intent, live = true)
    }

    /**
     * Only content:// URIs (the sender grants read access per URI) and .xrcfg files outside this app's private
     * storage may be read for import. Any app can send a VIEW intent with a file:// URI, and this app would
     * open it with its own permissions, so private files (saved profiles) must never be readable that way.
     */
    private fun isSafeImportUri(u: Uri): Boolean {
        return when (u.scheme) {
            "content" -> true
            "file" -> {
                val path = u.path ?: return false
                if (!path.endsWith(".xrcfg")) return false
                val own = java.io.File(applicationInfo.dataDir).canonicalPath
                !java.io.File(path).canonicalPath.startsWith(own)
            }
            else -> false
        }
    }

    /** xrayvpn:// links, shared .xrcfg files and shared text become an import request for Dart. */
    private fun handleIncoming(i: Intent?, live: Boolean) {
        if (i == null) return
        val stream: Uri? =
            if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else @Suppress("DEPRECATION") i.getParcelableExtra(Intent.EXTRA_STREAM)
        val uri: Uri? = i.data ?: stream
        val text: String? = when {
            uri != null && uri.scheme == "xrayvpn" -> uri.toString()
            uri != null && isSafeImportUri(uri) -> try {
                contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText().take(2_000_000) }
            } catch (_: Exception) { null }
            uri != null -> null
            i.action == Intent.ACTION_SEND -> i.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        }
        if (text.isNullOrBlank()) return
        if (live && VpnEvents.sink != null) VpnEvents.importText(text) else initial = text
    }

    /** Runs a blocking v2tun call off the UI thread and reports the outcome on it. */
    private fun <T> background(result: MethodChannel.Result, code: String, work: () -> T) {
        Thread {
            try {
                val v = work()
                runOnUiThread { result.success(v) }
            } catch (t: Throwable) {
                runOnUiThread { result.error(code, t.message ?: t.toString(), null) }
            }
        }.apply { isDaemon = true }.start()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "io.surprise.vpn/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { VpnEvents.sink = sink }
            override fun onCancel(args: Any?) { VpnEvents.sink = null }
        })

        MethodChannel(messenger, "io.surprise.vpn/core").setMethodCallHandler { call, result ->
            when (call.method) {
                "prepare" -> {
                    val i = VpnService.prepare(this)
                    if (i == null) result.success(true)
                    else {
                        pending = result
                        vpnConsent.launch(i)
                    }
                }
                "start" -> {
                    val cfg = call.argument<String>("config")
                    val opts = call.argument<Map<String, Any?>>("opts") ?: emptyMap()
                    if (cfg == null) { result.error("bad_args", "config missing", null); return@setMethodCallHandler }
                    val i = XRayVpnService.startIntent(this, cfg, JSONObject(opts).toString())
                    if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                    result.success(null)
                }
                "stop" -> {
                    startService(XRayVpnService.stopIntent(this))
                    result.success(null)
                }
                "status" -> result.success(VpnEvents.state)
                // Share link -> v2tun JSON config (the library's own parser; the name is under "name").
                "parseLink" -> {
                    val link = call.argument<String>("link")
                    if (link == null) { result.error("bad_args", "link missing", null); return@setMethodCallHandler }
                    background(result, "parse") { V2Tun.parseLink(link) }
                }
                // Latency in ms of a request (an HTTP URL) through a v2tun config.
                "ping" -> {
                    val cfg = call.argument<String>("config")
                    val url = call.argument<String>("url") ?: "http://www.gstatic.com/generate_204"
                    if (cfg == null) { result.error("bad_args", "config missing", null); return@setMethodCallHandler }
                    V2Tun.installProtector() // no VPN service yet is fine: the protector then allows the socket
                    background(result, "ping") { V2Tun.ping(cfg, url) }
                }
                // SSH host key fingerprint ("SHA256:...") of the server in a v2tun config, without logging in.
                "probeHostKey" -> {
                    val cfg = call.argument<String>("config")
                    val timeout = call.argument<Int>("timeoutSec") ?: 20
                    if (cfg == null) { result.error("bad_args", "config missing", null); return@setMethodCallHandler }
                    background(result, "hostkey") { V2Tun.probeHostKey(cfg, timeout) }
                }
                // Payload helpers of the library: validate (error text or null), preview, built-in presets.
                "validatePayload" -> result.success(V2Tun.validatePayload(call.argument<String>("template") ?: ""))
                "previewPayload" -> {
                    val tpl = call.argument<String>("template") ?: ""
                    val host = call.argument<String>("host") ?: "example.com"
                    val port = call.argument<Int>("port") ?: 22
                    background(result, "preview") { V2Tun.previewPayload(tpl, host, port) }
                }
                "payloadPresets" -> result.success(V2Tun.payloadPresets())
                // Whole-config check without connecting: null when valid, otherwise the reason.
                "validate" -> {
                    val cfg = call.argument<String>("config")
                    if (cfg == null) { result.error("bad_args", "config missing", null); return@setMethodCallHandler }
                    background(result, "validate") { V2Tun.validate(cfg) }
                }
                // What the config's payload sends and how the reply is checked.
                "payloadPreview" -> {
                    val cfg = call.argument<String>("config")
                    if (cfg == null) { result.error("bad_args", "config missing", null); return@setMethodCallHandler }
                    background(result, "preview") { V2Tun.payloadPreview(cfg) }
                }
                // Download speed through a config (its own connection, so it works with or without the VPN).
                "speedTest" -> {
                    val cfg = call.argument<String>("config")
                    val url = call.argument<String>("url") ?: ""
                    val seconds = call.argument<Int>("seconds") ?: 10
                    if (cfg == null) { result.error("bad_args", "config missing", null); return@setMethodCallHandler }
                    background(result, "speed") { V2Tun.speedTest(cfg, url, seconds) }
                }
                // Bug-host / SNI / server scan: one try of the config per candidate value.
                "scanHosts" -> {
                    val cfg = call.argument<String>("config")
                    val field = call.argument<String>("field") ?: "payload.host"
                    val values = call.argument<String>("values") ?: ""
                    val target = call.argument<String>("target") ?: ""
                    val jobs = call.argument<Int>("concurrency") ?: 3
                    val seconds = call.argument<Int>("seconds") ?: 15
                    if (cfg == null) { result.error("bad_args", "config missing", null); return@setMethodCallHandler }
                    background(result, "scan") { V2Tun.scanHosts(cfg, field, values, target, jobs, seconds) }
                }
                // Dial host:port through a config and close again.
                "probe" -> {
                    val cfg = call.argument<String>("config")
                    val target = call.argument<String>("target") ?: ""
                    if (cfg == null) { result.error("bad_args", "config missing", null); return@setMethodCallHandler }
                    background(result, "probe") { V2Tun.probe(cfg, target); true }
                }
                // 0 = main config, 1.. = backup in use, -1 = nothing running.
                "activeOutbound" -> result.success(V2Tun.activeOutbound())
                // How the running tunnel routes a connection: {"action":"direct","rule":"..."}.
                "explainRoute" -> {
                    val net = call.argument<String>("network") ?: "tcp"
                    val addr = call.argument<String>("addr") ?: ""
                    val proto = call.argument<String>("protocol") ?: ""
                    background(result, "route") { V2Tun.explainRoute(net, addr, proto) }
                }
                // Swap the routing section of the running tunnel; returns an error text or null.
                "updateRouting" -> result.success(V2Tun.updateRouting(call.argument<String>("routing") ?: "{}"))
                // Hand downloaded route lists (name -> file name in filesDir/routelists) to the running tunnel.
                "applyRouteLists" -> {
                    val files = call.argument<Map<String, String>>("files") ?: emptyMap()
                    background(result, "lists") { V2Tun.setRouteLists(File(filesDir, "routelists"), JSONObject(files)) }
                }
                "initialLink" -> { result.success(initial); initial = null }
                "requestIgnoreBattery" -> {
                    val pm = getSystemService(PowerManager::class.java)
                    if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                        startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
                    }
                    result.success(null)
                }
                "isRooted" -> result.success(isRooted())
                "setSecure" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    runOnUiThread {
                        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                "diagnostics" -> result.success(diagnostics())
                "openNotificationSettings" -> {
                    startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
                    result.success(null)
                }
                "openDataSaverSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_IGNORE_BACKGROUND_DATA_RESTRICTIONS_SETTINGS, Uri.parse("package:$packageName")))
                    } catch (_: Exception) { startActivity(Intent(Settings.ACTION_SETTINGS)) }
                    result.success(null)
                }
                "installedApps" -> result.success(listApps())
                "openVpnSettings" -> { startActivity(Intent(Settings.ACTION_VPN_SETTINGS)); result.success(null) }
                "openBatterySettings" -> {
                    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Cheap, best-effort root hints. Not a security boundary. */
    private fun isRooted(): Boolean {
        if (Build.TAGS?.contains("test-keys") == true) return true
        val paths = listOf("/system/bin/su", "/system/xbin/su", "/sbin/su", "/su/bin/su", "/system/sbin/su", "/data/local/xbin/su",
            "/data/local/bin/su", "/system/app/Superuser.apk", "/data/adb/magisk", "/sbin/.magisk")
        return paths.any { java.io.File(it).exists() }
    }

    private fun diagnostics(): Map<String, Any?> {
        val pm = getSystemService(PowerManager::class.java)
        val cm = getSystemService(android.net.ConnectivityManager::class.java)
        val nm = getSystemService(android.app.NotificationManager::class.java)
        return mapOf(
            "release" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
            "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "?"),
            "vpnGranted" to (VpnService.prepare(this) == null),
            "notifications" to (if (Build.VERSION.SDK_INT >= 24) nm.areNotificationsEnabled() else true),
            "batteryExempt" to pm.isIgnoringBatteryOptimizations(packageName),
            "dataSaver" to (if (Build.VERSION.SDK_INT >= 24) cm.restrictBackgroundStatus else null),
            "rooted" to isRooted(),
            "running" to XRayVpnService.running,
        )
    }

    private fun listApps(): List<Map<String, String>> {
        val pm = packageManager
        val launch = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(launch, PackageManager.MATCH_ALL)
            .map { mapOf("package" to it.activityInfo.packageName, "label" to it.loadLabel(pm).toString()) }
            .filter { it["package"] != packageName }
            .distinctBy { it["package"] }
            .sortedBy { it["label"]!!.lowercase() }
    }
}
