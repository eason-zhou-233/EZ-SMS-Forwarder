package com.example.sms_forwarder

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Telephony
import android.telephony.SmsMessage
import android.util.Log

/**
 * 短信广播接收器 —— 用于在 SmsForwardService 内部注册
 * 收到短信后通过回调交给 Service 处理
 */
class SmsReceiver(
    private val onSmsReceived: (sender: String, body: String) -> Unit
) : BroadcastReceiver() {

    companion object {
        const val TAG = "EZ-SMS-Receiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "========== onReceive START ==========")
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
                Log.d(TAG, "处理第 $index 条短信...")
                val sender = msg.originatingAddress ?: msg.displayOriginatingAddress ?: "未知号码"
                val body = msg.messageBody ?: msg.displayMessageBody ?: ""
                Log.d(TAG, "发件人: $sender, 内容长度: ${body.length}")
                Log.d(TAG, "准备回调 onSmsReceived...")
                onSmsReceived(sender, body)
                Log.d(TAG, "onSmsReceived 回调完成")
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
