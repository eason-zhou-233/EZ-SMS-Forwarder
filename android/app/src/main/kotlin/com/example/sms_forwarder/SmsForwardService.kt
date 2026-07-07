package com.example.sms_forwarder

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.telephony.SmsManager
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * 短信转发核心前台服务 —— 原生实现
 * 负责：SMS 监听、规则匹配、转发执行、通知栏常驻、划掉自启、开机自启
 */
class SmsForwardService : Service() {

    companion object {
        const val TAG = "EZ-SMS"
        const val CHANNEL_ID = "sms_forward_service_channel"
        const val NOTIFICATION_ID = 888
        const val CHANNEL_NAME = "短信转发监控"

        // MethodChannel 名称，与 Flutter 端一致
        const val METHOD_CHANNEL = "com.example.sms_forwarder/service"

        // 广播 Action
        const val ACTION_STOP = "com.example.sms_forwarder.STOP_SERVICE"

        // SharedPreferences Key
        const val PREFS_NAME = "flutter_shared"
        const val KEY_RULES = "flutter.forward_rules"
        const val KEY_SMTP_HOST = "flutter.smtp_host"
        const val KEY_SMTP_PORT = "flutter.smtp_port"
        const val KEY_SMTP_USER = "flutter.smtp_user"
        const val KEY_SMTP_PASSWORD = "flutter.smtp_password"

        // Flutter setStringList 编码前缀
        const val JSON_LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu!"
    }

    private lateinit var prefs: SharedPreferences
    private var wakeLock: PowerManager.WakeLock? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "SmsForwardService onCreate")

        prefs = applicationContext.getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE
        )

        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("正在后台运行..."))

        // 获取 WakeLock 防止 CPU 休眠
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "$TAG:WakeLock"
            )
            wakeLock?.acquire(10 * 60 * 1000L) // 10 分钟超时
        } catch (e: Exception) {
            Log.e(TAG, "获取 WakeLock 失败: ${e.message}")
        }

        // SMS Receiver 已改为 AndroidManifest 中静态注册（SmsBroadcastReceiver）
        // 不再需要动态注册，避免 Android 14+ 的限制
        Log.d(TAG, "SmsForwardService 已启动，等待 SmsBroadcastReceiver 通知")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand, startId=$startId, action=${intent?.action}")

        // 处理来自 SmsBroadcastReceiver 的短信数据
        if (intent?.action == SmsBroadcastReceiver.ACTION_SMS_RECEIVED) {
            val sender = intent.getStringExtra(SmsBroadcastReceiver.EXTRA_SENDER) ?: "未知"
            val body = intent.getStringExtra(SmsBroadcastReceiver.EXTRA_BODY) ?: ""
            Log.d(TAG, "收到来自 SmsBroadcastReceiver 的短信: sender=$sender, bodyLen=${body.length}")
            scope.launch {
                processSms(sender, body)
            }
        }

        // 处理 Flutter 发来的命令
        intent?.let {
            when (it.action) {
                ACTION_STOP -> {
                    Log.d(TAG, "收到停止命令")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
        }

        return START_STICKY // 被系统杀死后自动重建
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // ====== 关键：划掉 App 后自动重启服务 ======
        Log.d(TAG, "onTaskRemoved —— 用户划掉了最近任务，即将通过 AlarmManager 重启服务")

        val restartIntent = Intent(applicationContext, SmsForwardService::class.java)
        val pendingIntent = PendingIntent.getService(
            this, 1, restartIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT
        )

        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.setExact(
            AlarmManager.RTC_WAKEUP,
            System.currentTimeMillis() + 500, // 500ms 后重启
            pendingIntent
        )

        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.d(TAG, "SmsForwardService onDestroy")
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        scope.cancel()
        super.onDestroy()
    }

    // =================== 通知栏 ===================

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "此通知确保转发服务在后台持续运行"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(content: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("EZ短信转发助手")
            .setContentText(content)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun updateNotification(content: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(content))
    }

    // =================== SMS 处理 ===================

    private suspend fun processSms(sender: String, body: String) {
        Log.d(TAG, "========== processSms START ==========")
        Log.d(TAG, "发件人: $sender")
        Log.d(TAG, "内容长度: ${body.length}")

        Log.d(TAG, "STEP1: 开始加载规则...")
        val rules = try {
            loadRules()
        } catch (e: Exception) {
            Log.e(TAG, "STEP1 加载规则异常: ${e.message}", e)
            Log.d(TAG, "========== processSms END (加载规则失败) ==========")
            return
        }
        Log.d(TAG, "STEP1: 加载完成，规则数=${rules.size}")

        Log.d(TAG, "STEP2: 开始匹配规则...")
        for ((index, rule) in rules.withIndex()) {
            Log.d(TAG, "STEP2: 匹配第 $index 条规则: 号码=${rule.targetNumber}, 关键词=${rule.keyword}, 方式=${rule.forwardType}")
            try {
                val numberMatch = isMatch(normalizePhone(sender), normalizePhone(rule.targetNumber), rule.numberMatchType)
                val keywordMatch = isMatch(body, rule.keyword, rule.keywordMatchType)
                Log.d(TAG, "STEP2: 号码匹配=$numberMatch, 关键词匹配=$keywordMatch")

                if (numberMatch && keywordMatch) {
                    Log.d(TAG, "STEP3: 规则匹配成功，准备转发: ${rule.forwardType}")
                    executeForward(rule, sender, body)
                    Log.d(TAG, "STEP3: 转发调用完成")
                    Log.d(TAG, "========== processSms END (匹配成功) ==========")
                    return
                }
            } catch (e: Exception) {
                Log.e(TAG, "STEP2 匹配异常: ${e.message}", e)
            }
        }
        Log.d(TAG, ">>> 无匹配规则，未转发 <<<")
        Log.d(TAG, "========== processSms END (无匹配) ==========")
    }

    // =================== 转发执行 ===================

    private fun executeForward(rule: ForwardRule, sender: String, body: String) {
        when (rule.forwardType) {
            "PushPlus推送" -> sendToPushPlus(rule, sender, body)
            "短信发送" -> sendBySms(rule, sender, body)
            "钉钉群" -> sendToDingTalk(rule, sender, body)
            "邮箱" -> sendByEmail(rule, sender, body)
            else -> Log.d(TAG, "未知转发方式: ${rule.forwardType}")
        }
    }

    private fun sendToPushPlus(rule: ForwardRule, sender: String, body: String) {
        if (rule.pushPlusToken.isEmpty()) {
            Log.d(TAG, "转发跳过: 未配置 PushPlus Token")
            return
        }
        scope.launch {
            try {
                val json = JSONObject().apply {
                    put("token", rule.pushPlusToken)
                    put("title", "【验证码】来自 $sender")
                    put("content", body)
                    put("channel", "wechat")
                    if (rule.pushPlusTopic.isNotEmpty()) put("topic", rule.pushPlusTopic)
                    if (rule.pushPlusTo.isNotEmpty()) put("to", rule.pushPlusTo)
                }
                val result = httpPost("https://www.pushplus.plus/send", json.toString())
                Log.d(TAG, "PushPlus转发成功: $result")
            } catch (e: Exception) {
                Log.e(TAG, "PushPlus转发失败: ${e.message}")
            }
        }
    }

    private fun sendBySms(rule: ForwardRule, sender: String, body: String) {
        if (rule.smsTargetNumber.isEmpty()) {
            Log.d(TAG, "转发跳过: 未配置短信目标号码")
            return
        }
        try {
            val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }
            val text = "【验证码】来自 $sender\n$body"
            smsManager.sendTextMessage(rule.smsTargetNumber, null, text, null, null)
            Log.d(TAG, "短信转发已发送")
        } catch (e: Exception) {
            Log.e(TAG, "短信转发失败: ${e.message}")
        }
    }

    private fun sendToDingTalk(rule: ForwardRule, sender: String, body: String) {
        if (rule.dingTalkAccessToken.isEmpty()) {
            Log.d(TAG, "转发跳过: 未配置钉钉 Access Token")
            return
        }
        scope.launch {
            try {
                val title = "短信转发 - 来自 $sender"
                val text = "**【验证码】**  \n**发件人：** $sender  \n**内容：** $body"
                val json = JSONObject().apply {
                    put("msgtype", "markdown")
                    put("markdown", JSONObject().apply {
                        put("title", title)
                        put("text", text)
                    })
                }
                val url = "https://oapi.dingtalk.com/robot/send?access_token=${rule.dingTalkAccessToken}"
                val result = httpPost(url, json.toString())
                Log.d(TAG, "钉钉转发成功: $result")
            } catch (e: Exception) {
                Log.e(TAG, "钉钉转发失败: ${e.message}")
            }
        }
    }

    private fun sendByEmail(rule: ForwardRule, sender: String, body: String) {
        if (rule.emailTarget.isEmpty()) {
            Log.d(TAG, "转发跳过: 未配置目标邮箱")
            return
        }
        scope.launch {
            try {
                val host = getPrefString(KEY_SMTP_HOST)
                val port = getPrefInt(KEY_SMTP_PORT, 465)
                val user = getPrefString(KEY_SMTP_USER)
                val password = getPrefString(KEY_SMTP_PASSWORD)

                if (host.isEmpty() || user.isEmpty() || password.isEmpty()) {
                    Log.d(TAG, "转发跳过: 未配置全局SMTP")
                    return@launch
                }

                sendMailViaSmtp(host, port, user, password, rule.emailTarget, sender, body)
            } catch (e: Exception) {
                Log.e(TAG, "邮箱转发失败: ${e.message}", e)
            }
        }
    }

    /**
     * 纯手工 SMTP 发送邮件（SSL 直连，不依赖 JavaMail）
     */
    private fun sendMailViaSmtp(
        host: String, port: Int, user: String, password: String,
        to: String, sender: String, body: String
    ) {
        try {
            val sslCtx = javax.net.ssl.SSLContext.getInstance("TLS")
            sslCtx.init(null, null, java.security.SecureRandom())
            val socket = sslCtx.socketFactory.createSocket(host, port)
            socket.soTimeout = 15000

            val reader = java.io.BufferedReader(java.io.InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
            val writer = java.io.BufferedWriter(java.io.OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8))

            fun readAll(): List<String> {
                val lines = mutableListOf<String>()
                while (true) {
                    val line = reader.readLine() ?: break
                    Log.d(TAG, "SMTP << $line")
                    lines.add(line)
                    // 以 "ddd "（数字+空格）开头是最后一行，以 "ddd-" 开头是多行延续
                    if (line.length >= 4 && line[3] == ' ') break
                }
                return lines
            }

            fun getCode(lines: List<String>): Int {
                return lines.firstOrNull()?.take(3)?.toIntOrNull() ?: 0
            }

            fun sendCommand(cmd: String): List<String> {
                Log.d(TAG, "SMTP >> $cmd")
                writer.write("$cmd\r\n")
                writer.flush()
                return readAll()
            }

            // 1. 读取 greeting
            var resp = readAll()
            var code = getCode(resp)
            if (code != 220) throw Exception("SMTP greeting 错误: ${resp.firstOrNull()}")

            // 2. HELO（QQ 邮箱对 EHLO 有时返回 502，先用 HELO）
            resp = sendCommand("HELO sms-forwarder")
            code = getCode(resp)
            if (code != 250) throw Exception("HELO 失败: ${resp.firstOrNull()}")

            // 3. AUTH LOGIN
            resp = sendCommand("AUTH LOGIN")
            code = getCode(resp)
            if (code != 334) throw Exception("AUTH LOGIN 失败: ${resp.firstOrNull()}")

            resp = sendCommand(android.util.Base64.encodeToString(user.toByteArray(), android.util.Base64.NO_WRAP))
            code = getCode(resp)
            if (code != 334) throw Exception("用户名发送失败: ${resp.firstOrNull()}")

            resp = sendCommand(android.util.Base64.encodeToString(password.toByteArray(), android.util.Base64.NO_WRAP))
            code = getCode(resp)
            if (code != 235) throw Exception("密码验证失败: ${resp.firstOrNull()}")

            // 4. MAIL FROM
            resp = sendCommand("MAIL FROM:<$user>")
            code = getCode(resp)
            if (code != 250) throw Exception("MAIL FROM 失败: ${resp.firstOrNull()}")

            // 5. RCPT TO
            resp = sendCommand("RCPT TO:<$to>")
            code = getCode(resp)
            if (code != 250) throw Exception("RCPT TO 失败: ${resp.firstOrNull()}")

            // 6. DATA
            resp = sendCommand("DATA")
            code = getCode(resp)
            if (code != 354) throw Exception("DATA 失败: ${resp.firstOrNull()}")

            // 7. 邮件内容
            val subjectB64 = android.util.Base64.encodeToString(
                "【自动转发】来自 $sender".toByteArray(Charsets.UTF_8),
                android.util.Base64.NO_WRAP
            )
            val bodyB64 = android.util.Base64.encodeToString(
                "发件人: $sender\r\n\r\n短信内容:\r\n$body".toByteArray(Charsets.UTF_8),
                android.util.Base64.NO_WRAP
            )

            val emailContent = buildString {
                append("From: EZ短信转发助手 <$user>\r\n")
                append("To: <$to>\r\n")
                append("Subject: =?UTF-8?B?$subjectB64?=\r\n")
                append("MIME-Version: 1.0\r\n")
                append("Content-Type: text/plain; charset=UTF-8\r\n")
                append("Content-Transfer-Encoding: base64\r\n")
                append("\r\n")
                append(bodyB64)
                append("\r\n.\r\n")
            }

            writer.write(emailContent)
            writer.flush()
            resp = readAll()
            code = getCode(resp)
            if (code != 250) throw Exception("邮件发送失败: ${resp.firstOrNull()}")

            // 8. QUIT
            try {
                sendCommand("QUIT")
            } catch (_: Exception) {}

            socket.close()
            Log.d(TAG, "邮箱转发成功 -> $to")
        } catch (e: Exception) {
            Log.e(TAG, "邮箱发送异常: ${e.message}", e)
        }
    }

    // =================== HTTP 工具 ===================

    private fun httpPost(urlString: String, jsonBody: String): String {
        val url = URL(urlString)
        val conn = url.openConnection() as HttpURLConnection
        return try {
            conn.requestMethod = "POST"
            conn.setRequestProperty("Content-Type", "application/json")
            conn.doOutput = true
            conn.connectTimeout = 10000
            conn.readTimeout = 10000

            conn.outputStream.use { os ->
                os.write(jsonBody.toByteArray(Charsets.UTF_8))
            }

            if (conn.responseCode in 200..299) {
                conn.inputStream.bufferedReader().readText()
            } else {
                conn.errorStream?.bufferedReader()?.readText() ?: "HTTP ${conn.responseCode}"
            }
        } finally {
            conn.disconnect()
        }
    }

    // =================== 规则加载 ===================

    data class ForwardRule(
        val targetNumber: String = "",
        val keyword: String = "",
        val numberMatchType: String = "精确匹配",
        val keywordMatchType: String = "包含",
        val forwardType: String = "钉钉群",
        val pushPlusToken: String = "",
        val pushPlusTopic: String = "",
        val pushPlusTo: String = "",
        val smsTargetNumber: String = "",
        val dingTalkAccessToken: String = "",
        val emailTarget: String = ""
    )

    private fun loadRules(): List<ForwardRule> {
        return try {
            Log.d(TAG, "loadRules: 开始读取 SharedPreferences, key=$KEY_RULES")
            val rawValue = prefs.getString(KEY_RULES, null)
            if (rawValue == null) {
                Log.d(TAG, "loadRules: 未找到规则数据 (rawValue=null)")
                return emptyList()
            }
            Log.d(TAG, "loadRules: rawValue 长度=${rawValue.length}, 前50字符=${rawValue.take(50)}")

            // 去掉 Flutter setStringList 的编码前缀
            val jsonStr = if (rawValue.startsWith(JSON_LIST_PREFIX)) {
                Log.d(TAG, "loadRules: 检测到 JSON_LIST_PREFIX，去除前缀")
                rawValue.substring(JSON_LIST_PREFIX.length)
            } else {
                Log.d(TAG, "loadRules: 无 JSON_LIST_PREFIX，直接使用")
                rawValue
            }

            if (jsonStr.isEmpty()) {
                Log.d(TAG, "loadRules: 去除前缀后为空")
                return emptyList()
            }
            Log.d(TAG, "loadRules: jsonStr 长度=${jsonStr.length}")

            val arr = JSONArray(jsonStr)
            Log.d(TAG, "loadRules: JSONArray 解析成功，共 ${arr.length()} 条")
            val result = (0 until arr.length()).map { i ->
                val itemStr = arr.getString(i)
                val obj = JSONObject(itemStr)
                ForwardRule(
                    targetNumber = obj.optString("targetNumber", ""),
                    keyword = obj.optString("keyword", ""),
                    numberMatchType = obj.optString("numberMatchType", "精确匹配"),
                    keywordMatchType = obj.optString("keywordMatchType", "包含"),
                    forwardType = obj.optString("forwardType", "钉钉群"),
                    pushPlusToken = obj.optString("pushPlusToken", ""),
                    pushPlusTopic = obj.optString("pushPlusTopic", ""),
                    pushPlusTo = obj.optString("pushPlusTo", ""),
                    smsTargetNumber = obj.optString("smsTargetNumber", ""),
                    dingTalkAccessToken = obj.optString("dingTalkAccessToken", ""),
                    emailTarget = obj.optString("emailTarget", "")
                )
            }
            Log.d(TAG, "loadRules: 解析完成，返回 ${result.size} 条规则")
            result
        } catch (e: Exception) {
            Log.e(TAG, "loadRules: 加载规则失败: ${e.message}", e)
            emptyList()
        }
    }

    // =================== 字符串匹配工具 ===================

    private fun normalizePhone(phone: String): String {
        var result = phone.replace(Regex("[\\s\\-()]"), "")
        if (result.startsWith("+")) result = result.substring(1)
        if (result.startsWith("86")) result = result.substring(2)
        return result
    }

    private fun isMatch(text: String, pattern: String, type: String): Boolean {
        if (pattern.isEmpty()) return true
        val t = text.trim()
        val p = pattern.trim()
        return when (type) {
            "精确匹配" -> t == p
            "以此开头" -> t.startsWith(p)
            "以此结尾" -> t.endsWith(p)
            "包含" -> t.contains(p)
            else -> t.contains(p)
        }
    }

    // =================== SharedPreferences 读取辅助 ===================

    /**
     * Flutter 的 SharedPreferences 在 Android 端存储时，key 会加 "flutter." 前缀。
     * 例如 key "forward_rules" → "flutter.forward_rules"
     */
    private fun getPrefString(key: String): String {
        return prefs.getString(key, "") ?: ""
    }

    private fun getPrefInt(key: String, default: Int): Int {
        return try {
            // Flutter SharedPreferences 在 Android 端存储数值型时用 Long
            // 直接用 prefs.getInt() 可能抛出 ClassCastException
            val value = prefs.all[key]
            when (value) {
                is Long -> value.toInt()
                is Int -> value
                is String -> value.toIntOrNull() ?: default
                else -> default
            }
        } catch (e: Exception) {
            default
        }
    }
}
