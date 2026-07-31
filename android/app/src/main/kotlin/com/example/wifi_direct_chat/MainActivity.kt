package com.example.wifi_direct_chat   // ← change if your package is different

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.webrtc.NetworkMonitorAutoDetect

class MainActivity : FlutterActivity() {
    private val CHANNEL = "wifi_direct_network_binder"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enableWifiDirect" -> {
                        val success = enableWifiDirect()
                        result.success(success)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun enableWifiDirect(): Boolean {
        return try {
            val networkMonitor = NetworkMonitorAutoDetect.getInstance()
            val method = networkMonitor.javaClass.getDeclaredMethod("setIncludeWifiDirect", Boolean::class.java)
            method.invoke(networkMonitor, true)
            Log.i("NetworkBinder", "✅ WebRTC Wi-Fi Direct enabled")
            true
        } catch (e: Exception) {
            Log.e("NetworkBinder", "❌ Failed to enable Wi-Fi Direct", e)
            false
        }
    }
}
