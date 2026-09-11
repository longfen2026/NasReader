package com.example.nas_reader

import java.io.File
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.NetworkInterface
import java.util.Collections
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import tailnetandroid.Service
import tailnetandroid.Tailnetandroid

class MainActivity: FlutterActivity() {
    private val tailnetExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val tailnetService: Service by lazy { Tailnetandroid.newService() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TAILNET_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "connect" -> connectTailnet(call, result)
                    "authorize" -> authorizeTailnet(result)
                    "status" -> getTailnetStatus(result)
                    "logout" -> logoutTailnet(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun connectTailnet(call: MethodCall, result: MethodChannel.Result) {
        val target = call.argument<String>("target")?.trim()
        if (target.isNullOrEmpty()) {
            result.error("invalid_target", "A Tailnet host:port target is required.", null)
            return
        }

        val stateDir = File(filesDir, "tailscale").absolutePath
        tailnetExecutor.execute {
            try {
                refreshTailnetInterfaces()
                val loopbackUrl = tailnetService.connect(stateDir, target)
                runOnUiThread { result.success(loopbackUrl) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "tailnet_connect_failed",
                        error.message ?: "Unable to connect to Tailnet.",
                        null,
                    )
                }
            }
        }
    }

    private fun authorizeTailnet(result: MethodChannel.Result) {
        val stateDir = File(filesDir, "tailscale").absolutePath
        tailnetExecutor.execute {
            try {
                refreshTailnetInterfaces()
                val status = tailnetService.authorize(stateDir)
                runOnUiThread { result.success(status) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "tailnet_authorize_failed",
                        error.message ?: "Unable to start Tailnet authorization.",
                        null,
                    )
                }
            }
        }
    }

    private fun getTailnetStatus(result: MethodChannel.Result) {
        val stateDir = File(filesDir, "tailscale").absolutePath
        tailnetExecutor.execute {
            try {
                refreshTailnetInterfaces()
                val status = tailnetService.status(stateDir)
                runOnUiThread { result.success(status) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "tailnet_status_failed",
                        error.message ?: "Unable to read Tailnet status.",
                        null,
                    )
                }
            }
        }
    }

    private fun logoutTailnet(result: MethodChannel.Result) {
        tailnetExecutor.execute {
            try {
                tailnetService.logout()
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "tailnet_logout_failed",
                        error.message ?: "Unable to log out from Tailnet.",
                        null,
                    )
                }
            }
        }
    }

    private fun refreshTailnetInterfaces() {
        val interfaces = JSONArray()
        for (networkInterface in Collections.list(NetworkInterface.getNetworkInterfaces())) {
            val addresses = JSONArray()
            for (address in Collections.list(networkInterface.inetAddresses)) {
                val prefixLength = when (address) {
                    is Inet4Address -> 32
                    is Inet6Address -> 128
                    else -> continue
                }
                addresses.put("${address.hostAddress.substringBefore('%')}/$prefixLength")
            }
            interfaces.put(
                JSONObject()
                    .put("name", networkInterface.name)
                    .put("index", networkInterface.index)
                    .put("mtu", networkInterface.mtu)
                    .put("isUp", networkInterface.isUp)
                    .put("isLoopback", networkInterface.isLoopback)
                    .put("addresses", addresses),
            )
        }
        tailnetService.setInterfacesJSON(interfaces.toString())
    }

    override fun onDestroy() {
        tailnetExecutor.shutdownNow()
        try {
            tailnetService.close()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    private companion object {
        const val TAILNET_CHANNEL = "nas_reader/tailnet"
    }
}