package io.surprise.vpn

import org.json.JSONObject

/**
 * Official XTLS/libXray Invoke API integration.
 * API v3 accepts the complete Xray JSON document in payload.xrayJson.
 */
object XrayCore {
    private const val API_VERSION = 3

    private fun invoke(request: JSONObject): JSONObject {
        val raw = libXray.LibXray.invoke(request.toString())
        return try {
            JSONObject(raw)
        } catch (e: Exception) {
            JSONObject()
                .put("success", false)
                .put("error", "Invalid libXray response: $raw")
        }
    }

    /**
     * Starts Xray using the complete JSON configuration.
     * The runtime TUN descriptor and asset directory are added to the
     * configuration root env, as required by upstream libXray.
     *
     * Returns null on success, otherwise the upstream error message.
     */
    fun start(configJson: String, datDir: String, tunFd: Int): String? {
        val config = try {
            JSONObject(configJson)
        } catch (e: Exception) {
            return "Invalid Xray configuration JSON: ${e.message}"
        }

        val env = config.optJSONObject("env") ?: JSONObject()
        env.put("xray.location.asset", datDir)
        env.put("xray.tun.fd", tunFd)
        config.put("env", env)

        val request = JSONObject()
            .put("apiVersion", API_VERSION)
            .put("method", "runXray")
            .put(
                "payload",
                JSONObject().put("xrayJson", config.toString())
            )

        val response = invoke(request)
        return if (response.optBoolean("success", false)) {
            null
        } else {
            response.optString("error").ifBlank {
                "libXray runXray failed without an error message"
            }
        }
    }

    /** Stops the managed Xray instance using the upstream API v3 contract. */
    fun stop(): String? {
        val request = JSONObject()
            .put("apiVersion", API_VERSION)
            .put("method", "stopXray")

        val response = invoke(request)
        return if (response.optBoolean("success", false)) {
            null
        } else {
            response.optString("error").ifBlank {
                "libXray stopXray failed"
            }
        }
    }
}
