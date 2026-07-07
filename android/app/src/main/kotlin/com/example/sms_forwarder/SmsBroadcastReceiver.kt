package com.example.sms_forwarder

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Telephony
import android.telephony.SmsMessage
import android.util.Log

/**
 * 短信广播接收器 —— 在 AndroidManifest 中静态注册
 * 收到短信后启动/通知 SmsForwardService 处理
 */
class SmsBroadcastReceiver : BroadcastReceiver() {

    companion object {
        const val TAG = "EZ-SMS-Broadcast"
        const val ACTION_SMS_RECEIVED = "com.example.sms_forwarder.SMS_RECEIVED"
        const val EXTRA_SENDER = "extra_sender"
        const val EXTRA_BODY = "extra_body"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "========== onReceive START ==========")
        Log.d(TAG, "action: ${intent.action}")

        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) {
            Log.d(TAG, "不是 SMS_RECEIVED action，跳过")
            return
        }

        try {
            Log.d(TAG, "开始解析短信 PDU...")
            val messages = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                Telephony.Sms.Intents.getMessagesFromIntent(intent)
            } else {
                @Suppress("DEPRECATION")
                getMessagesFromIntentDeprecated(intent)
            }
            Log.d(TAG, "解析完成，共 ${messages.size} 条短信")

            for ((index, msg) in messages.withIndex()) {
                val sender = msg.originatingAddress ?: msg.displayOriginatingAddress ?: "未知号码"
                val body = msg.messageBody ?: msg.displayMessageBody ?: ""
                Log.d(TAG, "发件人: $sender, 内容长度: ${body.length}")

                // 启动 Service 并把短信数据传过去
                val serviceIntent = Intent(context, SmsForwardService::class.java).apply {
                    action = ACTION_SMS_RECEIVED
                    putExtra(EXTRA_SENDER, sender)
                    putExtra(EXTRA_BODY, body)
                }
                Log.d(TAG, "启动 SmsForwardService 并传递短信数据...")
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(serviceIntent)
                    } else {
                        context.startService(serviceIntent)
                    }
                    Log.d(TAG, "Service 启动命令已发送")
                } catch (e: Exception) {
                    Log.e(TAG, "启动 Service 失败: ${e.message}", e)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "处理短信失败: ${e.message}", e)
        }
        Log.d(TAG, "========== onReceive END ==========")
    }

    @Suppress("DEPRECATION")
    private fun getMessagesFromIntentDeprecated(intent: Intent): Array<SmsMessage> {
        val pdus = intent.getSerializableExtra("pdus") as? Array<*> ?: return emptyArray()
        val messages = Array(pdus.size) { i ->
            SmsMessage.createFromPdu(pdus[i] as ByteArray)
        }
        return messages
    }
}
