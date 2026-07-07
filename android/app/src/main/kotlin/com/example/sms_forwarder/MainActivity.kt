package com.example.sms_forwarder

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val TAG = "EZ-SMS-Main"
        const val METHOD_CHANNEL = "com.example.sms_forwarder/service"
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    Log.d(TAG, "Flutter 请求启动服务")
                    startSmsForwardService()
                    result.success(true)
                }
                "stopService" -> {
                    Log.d(TAG, "Flutter 请求停止服务")
                    stopSmsForwardService()
                    result.success(true)
                }
                "isServiceRunning" -> {
                    result.success(isSmsForwardServiceRunning())
                }
                "rulesUpdated" -> {
                    Log.d(TAG, "Flutter 通知规则已更新")
                    // 原生 Service 每次处理短信时会重新读取 SharedPreferences，
                    // 所以这里无需额外操作
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun startSmsForwardService() {
        val intent = Intent(this, SmsForwardService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopSmsForwardService() {
        val intent = Intent(this, SmsForwardService::class.java).apply {
            action = SmsForwardService.ACTION_STOP
        }
        startService(intent)
    }

    private fun isSmsForwardServiceRunning(): Boolean {
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        for (service in manager.getRunningServices(Integer.MAX_VALUE)) {
            if (SmsForwardService::class.java.name == service.service.className) {
                return true
            }
        }
        return false
    }
}
