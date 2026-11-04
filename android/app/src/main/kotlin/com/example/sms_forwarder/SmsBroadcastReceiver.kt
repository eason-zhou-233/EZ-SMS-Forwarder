package com.example.sms_forwarder

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Telephony
import android.util.Log

/** 在广播返回前保存完整短信，允许服务在进程重建后继续发送。 */
class SmsBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION ||
            !SmsForwardService.monitoringEnabled(context)) return
        try {
            val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            val grouped = messages.groupBy {
                it.originatingAddress ?: it.displayOriginatingAddress ?: "未知号码"
            }
            for ((sender, parts) in grouped) {
                val body = parts.joinToString("") { it.messageBody ?: it.displayMessageBody ?: "" }
                SmsForwardService.enqueueSms(context, sender, body)
            }
            if (grouped.isEmpty()) return
        } catch (e: Exception) {
            SmsForwardService.recordEvent(context, "短信保存失败：${e.javaClass.simpleName}")
            Log.e("EZ-SMS-Broadcast", "短信保存失败：${e.javaClass.simpleName}")
        }
        // 即使本次入队失败，也尝试恢复服务以排空此前已保存的任务。
        try {
            val service = Intent(context, SmsForwardService::class.java).apply {
                action = SmsForwardService.ACTION_DRAIN
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(service)
            else context.startService(service)
        } catch (e: Exception) {
            // 已持久化的任务不会因为启动受限而被删除，待后续启动时恢复。
            SmsForwardService.recordEvent(context, "后台启动失败：${e.javaClass.simpleName}")
            Log.e("EZ-SMS-Broadcast", "后台启动失败：${e.javaClass.simpleName}")
        }
    }
}
