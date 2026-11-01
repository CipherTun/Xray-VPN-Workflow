package io.surprise.vpn

import org.json.JSONObject

/**
 * Thin wrapper over libXray (gomobile AAR built from XTLS/libXray against
 * Xray-core v26.10.21 by scripts/build_cores.sh).
 *
 * libXray exposes one structured entry point, `LibXray.invoke(requestJSON)`.
 * The request/response envelope below follows the libXray README for the
 * 26.x line. If you build a different libXray tag, check the README and adjust
 * only this file.
 */
object XrayCore {
    private fun invoke(req: JSONObject): JSONObject {
        val raw = libXray.LibXray.invoke(req.toString())
        return try {
            JSONObject(raw)
        } catch (e: Exception) {
            JSONObject().put("success", false).put("error", raw)
        }
    }

    /** Starts Xray with its `tun` inbound bound to [tunFd]. Returns an error message, or null on success. */
    fun start(configPath: String, datDir: String, tunFd: Int): String? {
        val env = JSONObject()
            .put("xray.location.asset", datDir)
            .put("xray.location.config", configPath)
            .put("xray.tun.fd", tunFd)
        val req = JSONObject()
            .put("apiVersion", 1)
            .put("method", "runXray")
            .put("env", env)
            .put("payload", JSONObject().put("datDir", datDir).put("configPath", configPath))
        val r = invoke(req)
        return if (r.optBoolean("success")) null else r.optString("error", "Xray failed to start")
    }

    fun stop() {
        invoke(JSONObject().put("apiVersion", 1).put("method", "stopXray"))
    }
}
