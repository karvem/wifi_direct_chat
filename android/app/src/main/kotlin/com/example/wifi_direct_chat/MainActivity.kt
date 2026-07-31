package com.example.wifi_direct_chat   // 如果你的包名不同，请修改这里

import android.net.ConnectivityManager
import android.net.LinkAddress
import android.net.LinkProperties
import android.net.Network
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "wifi_direct_network_binder"
    private var boundNetwork: Network? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
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

        // 找到包含该 IP 的网络接口
        val network = cm.allNetworks.firstOrNull { net ->
            val lp = cm.getLinkProperties(net)
            if (lp == null) {
                false
            } else {
                // 使用正确的方法名 getLinkAddresses()
                lp.getLinkAddresses().any { addr: LinkAddress ->
                    val inetAddr = addr.getAddress()
                    inetAddr?.hostAddress == ipAddress
                }
            }
        }

        if (network == null) {
            android.util.Log.e("NetworkBinder", "No network found with IP $ipAddress")
            return false
        }

        // 将进程绑定到这个网络
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                cm.bindProcessToNetwork(network)
            } else {
                @Suppress("DEPRECATION")
                ConnectivityManager.setProcessDefaultNetwork(network)
            }
            boundNetwork = network
            android.util.Log.i("NetworkBinder", "Bound to network: ${network.javaClass.name}")
            true
        } catch (e: Exception) {
            android.util.Log.e("NetworkBinder", "Failed to bind", e)
            false
        }
    }

    private fun unbindFromNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                cm.bindProcessToNetwork(null)
            } else {
                @Suppress("DEPRECATION")
                ConnectivityManager.setProcessDefaultNetwork(null)
            }
            boundNetwork = null
            android.util.Log.i("NetworkBinder", "Unbound from network")
        } catch (e: Exception) {
            android.util.Log.e("NetworkBinder", "Failed to unbind", e)
        }
    }
}
