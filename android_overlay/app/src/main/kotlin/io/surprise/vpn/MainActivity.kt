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
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val reqVpn = 0x56
    private var pending: MethodChannel.Result? = null
    private var initial: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncoming(intent, live = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncoming(intent, live = true)
    }

    /** xrayvpn:// links, shared .xrcfg files and shared text become an import request for Dart. */
    private fun handleIncoming(i: Intent?, live: Boolean) {
        if (i == null) return
        @Suppress("DEPRECATION")
        val uri: Uri? = i.data ?: i.getParcelableExtra(Intent.EXTRA_STREAM)
        val text: String? = when {
            uri != null && uri.scheme == "xrayvpn" -> uri.toString()
            uri != null -> try {
                contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText().take(2_000_000) }
            } catch (_: Exception) { null }
            i.action == Intent.ACTION_SEND -> i.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        }
        if (text.isNullOrBlank()) return
        if (live && VpnEvents.sink != null) VpnEvents.importText(text) else initial = text
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
                        @Suppress("DEPRECATION") startActivityForResult(i, reqVpn)
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

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == reqVpn) {
            pending?.success(resultCode == RESULT_OK)
            pending = null
        } else {
            @Suppress("DEPRECATION") super.onActivityResult(requestCode, resultCode, data)
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
