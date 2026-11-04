package com.example.sms_forwarder

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.ContactsContract
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val TAG = "EZ-SMS-Main"
        const val METHOD_CHANNEL = "com.example.sms_forwarder/service"
        private const val REQUEST_PICK_CONTACT = 1001
    }

    private var pendingContactResult: MethodChannel.Result? = null

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_PICK_CONTACT) {
            if (resultCode != Activity.RESULT_OK || data == null) {
                pendingContactResult?.success("")
                pendingContactResult = null
                return
            }
            try {
                val cursor: Cursor? = contentResolver.query(data.data!!, null, null, null, null)
                val phone = cursor?.use {
                    if (it.moveToFirst()) {
                        val idx = it.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
                        if (idx >= 0) it.getString(idx) ?: "" else ""
                    } else ""
                } ?: ""
                pendingContactResult?.success(phone)
            } catch (e: Exception) {
                Log.e(TAG, "读取联系人号码失败: ${e.message}")
                pendingContactResult?.success("")
            }
            pendingContactResult = null
        }
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
                    handleServiceStart(result, true)
                }
                "ensureService" -> {
                    handleServiceStart(result, false)
                }
                "getDiagnostics" -> {
                    result.success(SmsForwardService.diagnostics(this))
                }
                "stopService" -> {
                    Log.d(TAG, "Flutter 请求停止服务")
                    try {
                        SmsForwardService.setMonitoringEnabled(this, false)
                        stopService(Intent(this, SmsForwardService::class.java))
                        SmsForwardService.recordEvent(this, "监控已主动停止，待转发任务已清除")
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_STOP_FAILED", "停止监控失败", null)
                    }
                }
                "isServiceRunning" -> {
                    result.success(isSmsForwardServiceRunning())
                }
                "rulesUpdated" -> {
                    Log.d(TAG, "Flutter 通知规则已更新")
                    result.success(true)
                }
                "pickContact" -> {
                    Log.d(TAG, "Flutter 请求选择联系人")
                    pendingContactResult = result
                    try {
                        val intent = Intent(Intent.ACTION_PICK).apply {
                            setData(ContactsContract.CommonDataKinds.Phone.CONTENT_URI)
                        }
                        startActivityForResult(intent, REQUEST_PICK_CONTACT)
                    } catch (e: Exception) {
                        Log.e(TAG, "启动联系人选择失败: ${e.message}")
                        pendingContactResult = null
                        result.success("")
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun handleServiceStart(result: MethodChannel.Result, userInitiated: Boolean) {
        try {
            if (userInitiated) SmsForwardService.setMonitoringEnabled(this, true)
            if (!SmsForwardService.monitoringEnabled(this)) {
                result.success(false)
                return
            }
            val intent = Intent(this, SmsForwardService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
            else startService(intent)
            result.success(true)
        } catch (e: Exception) {
            SmsForwardService.recordEvent(this, "启动请求被拒绝：${e.javaClass.simpleName}")
            result.error("SERVICE_START_FAILED", "系统未接受后台服务启动请求", null)
        }
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
