package com.example.sms_forwarder

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import kotlinx.coroutines.channels.Channel
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.SSLSocket
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
 * 负责：短信转发、任务持久化、前台监控和开机恢复
 */
class SmsForwardService : Service() {

    companion object {
        const val TAG = "EZ-SMS"
        const val CHANNEL_ID = "sms_forward_service_channel"
        const val NOTIFICATION_ID = 888
        const val CHANNEL_NAME = "短信转发监控"
        const val ACTION_STOP = "com.example.sms_forwarder.STOP_SERVICE"
        const val ACTION_DRAIN = "com.example.sms_forwarder.DRAIN_QUEUE"
        const val KEY_RULES = "flutter.forward_rules"
        const val KEY_SMTP_HOST = "flutter.smtp_host"
        const val KEY_SMTP_PORT = "flutter.smtp_port"
        const val KEY_SMTP_USER = "flutter.smtp_user"
        const val KEY_SMTP_PASSWORD = "flutter.smtp_password"
        const val JSON_LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu!"
        private const val RUNTIME_PREFS = "sms_forward_runtime"
        private var pendingQueue: PendingForwardQueue? = null

        private fun runtimePrefs(context: Context): SharedPreferences =
            context.applicationContext.getSharedPreferences(RUNTIME_PREFS, Context.MODE_PRIVATE)

        @Synchronized
        internal fun queue(context: Context): PendingForwardQueue {
            return pendingQueue ?: run {
                val storage = runtimePrefs(context)
                PendingForwardQueue(
                    read = { storage.getString("pending", "[]") ?: "[]" },
                    write = { storage.edit().putString("pending", it).commit() }
                ).also { pendingQueue = it }
            }
        }

        fun monitoringEnabled(context: Context): Boolean =
            runtimePrefs(context).getBoolean("monitoring_enabled", true)

        fun setMonitoringEnabled(context: Context, enabled: Boolean) {
            check(runtimePrefs(context).edit().putBoolean("monitoring_enabled", enabled).commit()) {
                "无法保存监控状态"
            }
            if (!enabled) queue(context).clear()
        }

        @Synchronized
        fun recordEvent(context: Context, message: String) {
            val storage = runtimePrefs(context)
            val time = System.currentTimeMillis()
            val previous = try { JSONArray(storage.getString("events", "[]")) }
                catch (_: Exception) { JSONArray() }
            val events = JSONArray()
            for (index in (previous.length() - 19).coerceAtLeast(0) until previous.length()) {
                events.put(previous.getJSONObject(index))
            }
            events.put(JSONObject().put("time", time).put("message", message))
            storage.edit().putString("last_event", message).putLong("last_event_at", time)
                .putString("events", events.toString()).apply()
        }

        fun enqueueSms(context: Context, sender: String, body: String) {
            queue(context).add(sender, body)
            runtimePrefs(context).edit().putLong("last_sms_at", System.currentTimeMillis()).apply()
        }

        fun diagnostics(context: Context): Map<String, String> {
            val state = runtimePrefs(context)
            val result = mutableMapOf(
                "enabled" to monitoringEnabled(context).toString(),
                "startedAt" to state.getLong("started_at", 0).toString(),
                "lastSmsAt" to state.getLong("last_sms_at", 0).toString(),
                "lastDeliveryAt" to state.getLong("last_delivery_at", 0).toString(),
                "lastEvent" to (state.getString("last_event", "暂无运行记录") ?: ""),
                "lastEventAt" to state.getLong("last_event_at", 0).toString(),
                "recentEvents" to (state.getString("events", "[]") ?: "[]"),
                "androidVersion" to Build.VERSION.RELEASE
            )
            result["pendingCount"] = try { queue(context).snapshot().size.toString() }
                catch (_: Exception) { "读取失败" }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                try {
                    val manager = context.getSystemService(ActivityManager::class.java)
                    manager.getHistoricalProcessExitReasons(context.packageName, 0, 1)
                        .firstOrNull()?.let { exit ->
                            result["lastExitAt"] = exit.timestamp.toString()
                            result["lastExitReason"] = when (exit.reason) {
                                ApplicationExitInfo.REASON_LOW_MEMORY -> "系统内存不足回收"
                                ApplicationExitInfo.REASON_CRASH -> "应用异常退出"
                                ApplicationExitInfo.REASON_CRASH_NATIVE -> "原生进程异常退出"
                                ApplicationExitInfo.REASON_ANR -> "应用无响应"
                                ApplicationExitInfo.REASON_USER_REQUESTED -> "用户或系统清理操作"
                                ApplicationExitInfo.REASON_USER_STOPPED -> "用户被停止"
                                ApplicationExitInfo.REASON_SIGNALED -> "进程收到终止信号（${exit.status}）"
                                ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "系统限制资源占用"
                                else -> "系统退出原因编号 ${exit.reason}"
                            }
                        }
                } catch (_: Exception) { /* 部分厂商未提供退出记录 */ }
            }
            return result
        }
    }

    private lateinit var prefs: SharedPreferences
    private var foregroundReady = false
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val workAvailable = Channel<Unit>(Channel.CONFLATED)

    override fun onCreate() {
        super.onCreate()
        prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        createNotificationChannel()
        try {
            val notification = buildNotification("正在后台等待短信")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, 0)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            recordEvent(this, "前台服务启动失败：${e.javaClass.simpleName}")
            stopSelf()
            return
        }
        foregroundReady = true
        runtimePrefs(this).edit().putLong("started_at", System.currentTimeMillis()).apply()
        recordEvent(this, "后台服务已启动")
        scope.launch { drainQueue() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!foregroundReady) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_STOP || !monitoringEnabled(this)) {
            scope.cancel()
            recordEvent(this, "监控已主动停止")
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        workAvailable.trySend(Unit)
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 前台服务不随最近任务移除而停止。避免用精确闹钟反而触发权限异常。
        recordEvent(this, "最近任务已移除，后台服务继续等待短信")
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        scope.cancel()
        workAvailable.close()
        // 尚未确认完成的任务仍留在磁盘，允许下次服务启动后恢复。
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
        try {
            manager.notify(NOTIFICATION_ID, buildNotification(content))
        } catch (_: SecurityException) {
            // 通知权限影响可见性，不改变已完成的投递结果。
            Log.w(TAG, "无法更新常驻通知，请检查通知权限")
        }
    }

    // =================== 持久化转发任务 ===================

    private class DeliveryException(message: String, val retryable: Boolean = true) : IOException(message)

    private suspend fun drainQueue() {
        val pending = queue(this)
        while (scope.isActive) {
            try {
                if (!monitoringEnabled(this)) return
                val tasks = pending.snapshot()
                val now = System.currentTimeMillis()
                val task = tasks.firstOrNull { it.nextAttemptAt <= now }
                if (task == null) {
                    val waitMs = tasks.minOfOrNull { it.nextAttemptAt - now }
                    if (waitMs == null) workAvailable.receive()
                    else withTimeoutOrNull(waitMs.coerceAtLeast(1)) { workAvailable.receive() }
                    continue
                }
                if (task.attempts >= PendingForwardQueue.MAX_ATTEMPTS) {
                    pending.remove(task.id)
                    recordEvent(this, "转发未完成：已达到重试次数上限")
                    continue
                }
                val rules = loadRules()
                val savedRule = task.ruleJson?.let { parseRule(JSONObject(it)) }
                if (savedRule != null && rules.none { it.enabled && it == savedRule }) {
                    pending.remove(task.id)
                    recordEvent(this, "规则已修改或暂停，取消原目标的待转发任务")
                    continue
                }
                val rule = savedRule ?: rules.firstOrNull {
                        it.enabled &&
                            isMatch(normalizePhone(task.sender), normalizePhone(it.targetNumber), it.numberMatchType) &&
                            isMatch(task.body, it.keyword, it.keywordMatchType)
                    }
                if (rule == null) {
                    pending.remove(task.id)
                    recordEvent(this, "收到短信，未命中启用的规则")
                    continue
                }
                // 发送前保存尝试次数和目标快照，恢复时不会转发到后来修改的目标。
                val claimed = pending.claim(task.id, rule.toJson().toString()) ?: continue
                sendPending(claimed, rule, pending)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val reason = if (e is DeliveryException) e.message else e.javaClass.simpleName
                recordEvent(this, "任务处理暂时失败：$reason")
                delay(15_000)
            }
        }
    }

    private suspend fun sendPending(task: PendingForward, rule: ForwardRule, pending: PendingForwardQueue) {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$TAG:Delivery")
        try {
            // 只在执行转发时持有有时限的锁，不让CPU整夜保持唤醒。
            lock.acquire(3 * 60 * 1000L)
            currentCoroutineContext().ensureActive()
            if (!monitoringEnabled(this)) return
            executeForward(rule, task.sender, task.body)
            currentCoroutineContext().ensureActive()
            pending.remove(task.id)
            runtimePrefs(this).edit().putLong("last_delivery_at", System.currentTimeMillis()).apply()
            val status = if (rule.forwardType == "短信发送") "短信已提交给系统（未确认送达）"
                else "${rule.forwardType}转发已被服务端接受"
            recordEvent(this, status)
            updateNotification(status)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val retry = rule.forwardType != "短信发送" &&
                (e !is DeliveryException || e.retryable) && task.attempts < PendingForwardQueue.MAX_ATTEMPTS
            if (!retry) pending.remove(task.id)
            val reason = if (e is DeliveryException) e.message else e.javaClass.simpleName
            val status = if (retry) "${rule.forwardType}转发失败，将重试（第${task.attempts}次）：$reason"
                else "${rule.forwardType}转发失败，已停止重试：$reason"
            recordEvent(this, status)
            updateNotification(if (retry) "转发暂未完成，等待重试" else "转发失败，点击查看运行记录")
        } finally {
            if (lock.isHeld) lock.release()
        }
    }

    // =================== 转发执行（在队列工作协程内完成） ===================

    private fun executeForward(rule: ForwardRule, sender: String, body: String) {
        when (rule.forwardType) {
            "PushPlus推送" -> sendToPushPlus(rule, sender, body)
            "短信发送" -> sendBySms(rule, sender, body)
            "钉钉群" -> sendToDingTalk(rule, sender, body)
            "邮箱" -> sendByEmail(rule, sender, body)
            else -> throw DeliveryException("未知转发方式", false)
        }
    }

    private fun sendToPushPlus(rule: ForwardRule, sender: String, body: String) {
        if (rule.pushPlusToken.isEmpty()) throw DeliveryException("未配置PushPlus Token", false)
        val json = JSONObject().apply {
            put("token", rule.pushPlusToken)
            put("title", "【验证码】来自 $sender")
            put("content", body)
            put("channel", "wechat")
            if (rule.pushPlusTopic.isNotEmpty()) put("topic", rule.pushPlusTopic)
            if (rule.pushPlusTo.isNotEmpty()) put("to", rule.pushPlusTo)
        }
        val response = JSONObject(httpPost("https://www.pushplus.plus/send", json.toString()))
        val code = response.optInt("code", -1)
        if (code != 200) throw DeliveryException("PushPlus返回错误码 $code", code == 500)
    }

    private fun sendBySms(rule: ForwardRule, sender: String, body: String) {
        if (rule.smsTargetNumber.isEmpty()) throw DeliveryException("未配置短信目标号码", false)
        val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
        smsManager.sendTextMessage(rule.smsTargetNumber, null, "【验证码】来自 $sender\n$body", null, null)
    }

    private fun sendToDingTalk(rule: ForwardRule, sender: String, body: String) {
        if (rule.dingTalkAccessToken.isEmpty()) throw DeliveryException("未配置钉钉Token", false)
        val json = JSONObject().apply {
            put("msgtype", "markdown")
            put("markdown", JSONObject().apply {
                put("title", "短信转发 - 来自 $sender")
                put("text", "**【验证码】**  \n**发件人：** $sender  \n**内容：** $body")
            })
        }
        val response = JSONObject(httpPost(
            "https://oapi.dingtalk.com/robot/send?access_token=${rule.dingTalkAccessToken}", json.toString()
        ))
        val code = response.optInt("errcode", -1)
        if (code != 0) throw DeliveryException("钉钉返回错误码 $code", false)
    }

    private fun sendByEmail(rule: ForwardRule, sender: String, body: String) {
        if (rule.emailTarget.isEmpty()) throw DeliveryException("未配置目标邮箱", false)
        val host = getPrefString(KEY_SMTP_HOST)
        val port = getPrefInt(KEY_SMTP_PORT, 465)
        val user = getPrefString(KEY_SMTP_USER)
        val password = getPrefString(KEY_SMTP_PASSWORD)
        if (host.isEmpty() || user.isEmpty() || password.isEmpty() || port !in 1..65535) {
            throw DeliveryException("SMTP配置不完整或端口无效", false)
        }
        sendMailViaSmtp(host, port, user, password, rule.emailTarget, sender, body)
    }

    /**
     * 纯手工 SMTP 发送邮件（SSL 直连，不依赖 JavaMail）
     */
    private fun sendMailViaSmtp(
        host: String, port: Int, user: String, password: String,
        to: String, sender: String, body: String
    ) {
        val transport = Socket()
        try {
            transport.connect(InetSocketAddress(host, port), 10000)
            transport.soTimeout = 15000
            val sslCtx = javax.net.ssl.SSLContext.getInstance("TLS")
            sslCtx.init(null, null, java.security.SecureRandom())
            (sslCtx.socketFactory.createSocket(transport, host, port, true) as SSLSocket).use { socket ->
                socket.soTimeout = 15000
                socket.sslParameters = socket.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
                socket.startHandshake()

                val reader = java.io.BufferedReader(java.io.InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
                val writer = java.io.BufferedWriter(java.io.OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8))

                fun readAll(): List<String> {
                    val lines = mutableListOf<String>()
                    while (true) {
                        val line = reader.readLine() ?: break
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
                    writer.write("$cmd\r\n")
                    writer.flush()
                    return readAll()
                }

                // 1. 读取 greeting
                var resp = readAll()
                var code = getCode(resp)
                if (code != 220) throw DeliveryException("SMTP返回状态 $code（预期220）", code == 0 || code in 400..499)

                // 2. HELO（QQ 邮箱对 EHLO 有时返回 502，先用 HELO）
                resp = sendCommand("HELO sms-forwarder")
                code = getCode(resp)
                if (code != 250) throw DeliveryException("SMTP返回状态 $code（预期250）", code == 0 || code in 400..499)

                // 3. AUTH LOGIN
                resp = sendCommand("AUTH LOGIN")
                code = getCode(resp)
                if (code != 334) throw DeliveryException("SMTP返回状态 $code（预期334）", code == 0 || code in 400..499)

                resp = sendCommand(android.util.Base64.encodeToString(user.toByteArray(), android.util.Base64.NO_WRAP))
                code = getCode(resp)
                if (code != 334) throw DeliveryException("SMTP返回状态 $code（预期334）", code == 0 || code in 400..499)

                resp = sendCommand(android.util.Base64.encodeToString(password.toByteArray(), android.util.Base64.NO_WRAP))
                code = getCode(resp)
                if (code != 235) throw DeliveryException("SMTP返回状态 $code（预期235）", code == 0 || code in 400..499)

                // 4. MAIL FROM
                resp = sendCommand("MAIL FROM:<$user>")
                code = getCode(resp)
                if (code != 250) throw DeliveryException("SMTP返回状态 $code（预期250）", code == 0 || code in 400..499)

                // 5. RCPT TO
                resp = sendCommand("RCPT TO:<$to>")
                code = getCode(resp)
                if (code != 250) throw DeliveryException("SMTP返回状态 $code（预期250）", code == 0 || code in 400..499)

                // 6. DATA
                resp = sendCommand("DATA")
                code = getCode(resp)
                if (code != 354) throw DeliveryException("SMTP返回状态 $code（预期354）", code == 0 || code in 400..499)

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
                    val displayName = android.util.Base64.encodeToString(
                        "EZ短信转发助手".toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP
                    )
                    append("From: =?UTF-8?B?$displayName?= <$user>\r\n")
                    append("To: <$to>\r\n")
                    append("Subject: =?UTF-8?B?$subjectB64?=\r\n")
                    append("MIME-Version: 1.0\r\n")
                    append("Content-Type: text/plain; charset=UTF-8\r\n")
                    append("Content-Transfer-Encoding: base64\r\n")
                    append("\r\n")
                    append(bodyB64.chunked(76).joinToString("\r\n"))
                    append("\r\n.\r\n")
                }

                writer.write(emailContent)
                writer.flush()
                resp = readAll()
                code = getCode(resp)
                if (code != 250) throw DeliveryException("SMTP返回状态 $code（预期250）", code == 0 || code in 400..499)

                // 8. QUIT
                try {
                    sendCommand("QUIT")
                } catch (_: Exception) {}

            }
        } finally {
            try { transport.close() } catch (_: IOException) {}
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

            val status = conn.responseCode
            if (status !in 200..299) {
                throw DeliveryException("HTTP $status", status >= 500 || status == 429 || status == 408)
            }
            conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
        } finally {
            conn.disconnect()
        }
    }

    // =================== 规则加载 ===================

    data class ForwardRule(
        val name: String = "",
        val targetNumber: String = "",
        val keyword: String = "",
        val numberMatchType: String = "精确匹配",
        val keywordMatchType: String = "包含",
        val forwardType: String = "钉钉群",
        val enabled: Boolean = true,
        val pushPlusToken: String = "",
        val pushPlusTopic: String = "",
        val pushPlusTo: String = "",
        val smsTargetNumber: String = "",
        val dingTalkAccessToken: String = "",
        val emailTarget: String = ""
    ) {
        fun toJson(): JSONObject = JSONObject().apply {
            put("name", name); put("targetNumber", targetNumber); put("keyword", keyword)
            put("numberMatchType", numberMatchType); put("keywordMatchType", keywordMatchType)
            put("forwardType", forwardType); put("enabled", enabled)
            put("pushPlusToken", pushPlusToken); put("pushPlusTopic", pushPlusTopic)
            put("pushPlusTo", pushPlusTo); put("smsTargetNumber", smsTargetNumber)
            put("dingTalkAccessToken", dingTalkAccessToken); put("emailTarget", emailTarget)
        }
    }

    private fun loadRules(): List<ForwardRule> {
        return try {
            Log.d(TAG, "loadRules: 开始读取 SharedPreferences, key=$KEY_RULES")
            val rawValue = prefs.getString(KEY_RULES, null)
            if (rawValue == null) {
                Log.d(TAG, "loadRules: 未找到规则数据 (rawValue=null)")
                return emptyList()
            }
            Log.d(TAG, "loadRules: rawValue 长度=${rawValue.length}")

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
                parseRule(obj)
            }
            Log.d(TAG, "loadRules: 解析完成，返回 ${result.size} 条规则")
            result
        } catch (e: Exception) {
            throw DeliveryException("规则读取失败，请检查配置", false)
        }
    }

    private fun parseRule(obj: JSONObject): ForwardRule = ForwardRule(
        name = obj.optString("name", ""),
        targetNumber = obj.optString("targetNumber", ""),
        keyword = obj.optString("keyword", ""),
        numberMatchType = obj.optString("numberMatchType", "精确匹配"),
        keywordMatchType = obj.optString("keywordMatchType", "包含"),
        forwardType = obj.optString("forwardType", "钉钉群"),
        enabled = obj.optBoolean("enabled", true),
        pushPlusToken = obj.optString("pushPlusToken", ""),
        pushPlusTopic = obj.optString("pushPlusTopic", ""),
        pushPlusTo = obj.optString("pushPlusTo", ""),
        smsTargetNumber = obj.optString("smsTargetNumber", ""),
        dingTalkAccessToken = obj.optString("dingTalkAccessToken", ""),
        emailTarget = obj.optString("emailTarget", "")
    )

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


/** 单进程串行队列，存储回调必须在返回前完成持久化。 */
internal data class PendingForward(
    val id: String,
    val sender: String,
    val body: String,
    val receivedAt: Long,
    val attempts: Int = 0,
    val nextAttemptAt: Long = receivedAt,
    val ruleJson: String? = null
)

internal class PendingForwardQueue(
    private val read: () -> String,
    private val write: (String) -> Boolean,
    private val now: () -> Long = System::currentTimeMillis
) {
    companion object {
        const val MAX_ATTEMPTS = 6
        const val MAX_AGE_MS = 30 * 60 * 1000L
        const val MAX_PENDING = 100
        fun retryDelay(attempt: Int): Long = (15_000L shl (attempt - 1).coerceIn(0, 5)).coerceAtMost(300_000L)
    }

    private fun load(): List<PendingForward> {
        val arr = JSONArray(read())
        val all = (0 until arr.length()).map { index ->
            val item = arr.getJSONObject(index)
            PendingForward(
                item.getString("id"), item.getString("sender"), item.getString("body"),
                item.getLong("receivedAt"), item.optInt("attempts"), item.getLong("nextAttemptAt"),
                if (item.isNull("ruleJson")) null else item.getString("ruleJson")
            )
        }
        val active = all.filter { now() - it.receivedAt < MAX_AGE_MS }
        if (active.size != all.size) save(active)
        return active
    }

    private fun save(tasks: List<PendingForward>) {
        val arr = JSONArray()
        tasks.forEach { task ->
            arr.put(JSONObject().apply {
                put("id", task.id); put("sender", task.sender); put("body", task.body)
                put("receivedAt", task.receivedAt); put("attempts", task.attempts)
                put("nextAttemptAt", task.nextAttemptAt); put("ruleJson", task.ruleJson ?: JSONObject.NULL)
            })
        }
        check(write(arr.toString())) { "无法持久化待转发任务" }
    }

    @Synchronized fun snapshot(): List<PendingForward> = load()

    @Synchronized fun add(sender: String, body: String) {
        val tasks = load()
        check(tasks.size < MAX_PENDING) { "待转发任务已达到容量上限" }
        save(tasks + PendingForward(java.util.UUID.randomUUID().toString(), sender, body, now()))
    }

    @Synchronized fun claim(id: String, ruleJson: String): PendingForward? {
        val tasks = load()
        val task = tasks.firstOrNull { it.id == id } ?: return null
        if (task.attempts >= MAX_ATTEMPTS || task.nextAttemptAt > now()) return null
        val next = task.copy(attempts = task.attempts + 1, ruleJson = task.ruleJson ?: ruleJson,
            nextAttemptAt = now() + retryDelay(task.attempts + 1))
        save(tasks.map { if (it.id == id) next else it })
        return next
    }

    @Synchronized fun remove(id: String) = save(load().filterNot { it.id == id })
    @Synchronized fun clear() = save(emptyList())
}
