package com.example.wifi_direct_app // TODO: Ensure this matches your actual package name

import android.net.ConnectivityManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.wifi_direct_app/network"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "bindToWifiDirect") {
                val ip = call.argument<String>("ip")
                val success = bindToWifiDirect(ip)
                result.success(success)
            } else if (call.method == "unbindProcess") {
                unbindProcess()
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun bindToWifiDirect(targetIp: String?): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            val networks = cm.allNetworks
            for (network in networks) {
                val linkProperties = cm.getLinkProperties(network)
                if (linkProperties != null) {
                    // Check if the interface is a P2P interface OR if it owns our LAN IP
                    val hasP2pInterface = linkProperties.interfaceName?.contains("p2p") == true
                    var hasTargetIp = false
                    
                    if (targetIp != null) {
                        for (linkAddress in linkProperties.linkAddresses) {
                            if (linkAddress.address.hostAddress == targetIp) {
                                hasTargetIp = true
                                break
                            }
                        }
                    }
                    
                    if (hasP2pInterface || hasTargetIp) {
                        return cm.bindProcessToNetwork(network)
                    }
                }
            }
        }
        return false
    }

    private fun unbindProcess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.bindProcessToNetwork(null)
        }
    }
}
