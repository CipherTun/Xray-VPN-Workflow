package io.surprise.vpn

import org.json.JSONObject
import java.io.File

/**
 * Adapter for XTLS/libXray v26.9.9.
 *
 * libXray accepts UTF-8 Xray JSON through Invoke API version 3.
 * Runtime environment values, including the Android TUN fd, belong
 * inside the Xray configuration's root "env" object.
 */
object XrayCore {
    private const val API_VERSION = 3

    private fun invoke(req: JSONObject): JSONObject {
        val raw = libXray.LibXray.invoke(req.toString())
        return try {
            JSONObject(raw)
        } catch (e: Exception) {
            JSONObject()
                .put("success", false)
                .put("error", "Invalid libXray response: $raw")
        }
    }

    /**
     * Starts Xray from the generated configuration file.
     * Returns null on success, otherwise an error message.
     */
    fun start(configPath: String, datDir: String, tunFd: Int): String? {
        val configFile = File(configPath)
        if (!configFile.isFile) {
            return "Xray configuration file does not exist: $configPath"
        }

        val config = try {
            JSONObject(configFile.readText(Charsets.UTF_8))
        } catch (e: Exception) {
            return "Unable to read Xray configuration: ${e.message}"
        }

        val existingEnv = config.opt("env")
        if (existingEnv != null && existingEnv !is JSONObject) {
            return "Invalid Xray configuration: root env must be a JSON object"
        }

        val env = (existingEnv as? JSONObject) ?: JSONObject().also {
            config.put("env", it)
        }

        env.put("xray.location.asset", datDir)
        env.put("xray.location.config", configPath)
        env.put("xray.tun.fd", tunFd)

        val payload = JSONObject()
            .put("xrayJson", config.toString())

        val request = JSONObject()
            .put("apiVersion", API_VERSION)
            .put("method", "runXray")
            .put("payload", payload)

        val response = invoke(request)

        return if (response.optBoolean("success")) {
            null
        } else {
            response.optString("error").ifBlank {
                "Xray failed to start"
            }
        }
    }

    fun stop() {
        val request = JSONObject()
            .put("apiVersion", API_VERSION)
            .put("method", "stopXray")

        invoke(request)
    }
}
