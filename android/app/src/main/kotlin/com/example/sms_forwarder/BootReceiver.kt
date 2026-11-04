package com.example.sms_forwarder

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/** 开机后恢复已启用的监控和磁盘上的未完成任务。 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED ||
            !SmsForwardService.monitoringEnabled(context)) return
        try {
            val service = Intent(context, SmsForwardService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(service)
            else context.startService(service)
        } catch (e: Exception) {
            SmsForwardService.recordEvent(context, "开机恢复被系统拒绝：${e.javaClass.simpleName}")
        }
    }
}
