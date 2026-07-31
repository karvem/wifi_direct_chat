package com.example.wifi_direct_chat

import io.flutter.embedding.android.FlutterActivity

// MainActivity.kt
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.InetAddress

class MainActivity : FlutterActivity() {
    private val CHANNEL = "wifi_direct_network_binder"
    private var boundNetwork: Network? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bindToNetwork" -> {
                        val ip = call.argument<String>("ip")
                        if (ip == null) {
                            result.error("INVALID_ARG", "IP address missing", null)
                            return@setMethodCallHandler
                        }
                        val success = bindToNetwork(ip)
                        result.success(success)
                    }
                    "unbindFromNetwork" -> {
                        unbindFromNetwork()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun bindToNetwork(ipAddress: String): Boolean {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return false

        // Get the Network that has an interface with the given IP
        val network = cm.allNetworks.firstOrNull { net ->
            val lp = cm.getLinkProperties(net) ?: return@firstOrNull false
            lp.addresses.any { addr -> addr.address.hostAddress == ipAddress }
        }

        if (network == null) {
            android.util.Log.e("NetworkBinder", "No network found with IP $ipAddress")
            return false
        }

        // Bind the process to this network
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                cm.bindProcessToNetwork(network)
            } else {
                // For older versions we use the deprecated method
                ConnectivityManager.setProcessDefaultNetwork(network)
            }
            boundNetwork = network
            android.util.Log.i("NetworkBinder", "Bound to network: ${network.javaClass.name}")
            return true
        } catch (e: Exception) {
            android.util.Log.e("NetworkBinder", "Failed to bind", e)
            return false
        }
    }

    private fun unbindFromNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                cm.bindProcessToNetwork(null)
            } else {
                ConnectivityManager.setProcessDefaultNetwork(null)
            }
            boundNetwork = null
            android.util.Log.i("NetworkBinder", "Unbound from network")
        } catch (e: Exception) {
            android.util.Log.e("NetworkBinder", "Failed to unbind", e)
        }
    }
}
