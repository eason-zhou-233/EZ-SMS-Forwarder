> 本报告为后台修复前的审查快照，原代码行号以当时版本为准。后台链路已做专项修改，当前状态与验证请见[后台修复记录](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/background-fix-2026-11-04.md)。

# EZ短信转发助手代码审查记录

审查日期：2026-11-04（Asia/Shanghai）。本轮只审查，没有修改业务源代码。审查与截图产物统一放在本项目 logs 目录；临时测试脚本放在 /private/tmp/ez_sms_audit，没有写入项目代码目录。

## 阅读和验证范围

完整读取了 lib 下两个 Dart 文件及 Android 下五个 Kotlin 文件，共2049行；读取了主 AndroidManifest、app/build.gradle.kts、pubspec、锁定依赖对应的 SharedPreferences 实现、现有合并清单、README和分析配置。

部分 OneDrive 文件仍是 compressed,dataless 占位文件，包括现有 widget_test.dart、顶层Gradle配置、iOS/macOS部分入口及Git元数据。普通读取和授权后的重试均因 Operation timed out 失败。因此不能声称所有平台工程文件都已完整阅读，也不能确认Android完整构建与Git基线。本报告对完整业务链路的结论来自上述已读取核心代码。

没有进行真机短信接收、真实第三方推送、SMTP账号登录、运营商发送、开机恢复或后台6小时耐久测试。下文区分了已动态复现的Flutter问题与静态代码/官方平台规则核对的问题。

## 当前运作逻辑

1. main() 初始化Flutter后先请求启动Android服务，再runApp。首页初始化时一次请求短信、通知、电话和忽略电池优化相关权限，然后加载规则、提示状态和SMTP配置。

2. Flutter只负责UI和配置：规则含名称、来源号码、内容关键词、两类匹配模式、启用状态以及一种转发方式的目标信息。通过SharedPreferences保存forward_rules字符串列表，元素各自是规则JSON。SMTP配置为全局host、port、user、password。

3. 静态 SmsBroadcastReceiver 接收 SMS_RECEIVED，解析PDU，当前逐段将sender和body传给 SmsForwardService。旧 SmsReceiver 已没有注册使用，不是当前第二条监听链路。

4. Service 创建常驻通知、获取一次10分钟WakeLock，并使用IO协程处理事件。每次收到事件重新读取SharedPreferences中的规则；enabled=false跳过；来源条件与关键词条件是AND关系；空条件匹配全部。匹配模式有包含、精确、前缀、后缀，大小写敏感。

5. 按列表顺序，命中第一条启用规则后就return，即只执行一个通道；既不是多规则同时发送，也不是失败后自动尝试下一条。

6. 四种通道：PushPlus HTTPS JSON；短信 SmsManager；钉钉机器人HTTPS Markdown；手写SMTP AUTH LOGIN发送Base64正文。网络和邮件通过额外协程执行，结果只写Logcat。

7. 服务返回START_STICKY；BootReceiver无条件开机启动；onTaskRemoved设置500ms后的精确闹钟恢复。Flutter停止操作只向服务发送ACTION_STOP，没有持久化用户停用意图。

8. Dart到Android的通道名一致。现锁定版本的FlutterSharedPreferences文件名、flutter.键前缀及JSON_LIST_PREFIX与原生读取匹配；smtp_port按Long读取也有兼容处理。这两处没有发现当前版本的必现不兼容。rulesUpdated处理虽为空，但服务每条短信重新loadRules，不能据此认定规则更新必然不生效。

## 界面布局

首页使用Material3、紫色主题。AppBar左侧应用名，右侧SMTP图标与监控启停按钮。下方依次是可条件显示的通知权限、短信权限、电池优化、自启动提示；随后是服务状态条和规则列表。右下角“+”新增规则。

规则卡片左侧显示来源、名称、号码匹配方式、关键词匹配方式、关键词、转发方式；右侧纵排暂停/启用、编辑、删除。暂停卡片置灰并显示“已暂停”。卡片未展示具体转发目标。

新增/编辑采用可滚动AlertDialog：名称→来源号码及通讯录选择→号码匹配→关键词→关键词匹配→通道→通道专属字段。默认钉钉；PushPlus提供token/topic/to；短信提供目标号码及联系人选择；邮箱提供目标邮箱并依赖全局SMTP；钉钉提供access_token。底部取消及添加/保存。

SMTP配置是独立弹窗，含服务器、端口、发件账号、授权码，底部取消/保存。删除另有确认弹窗。应用内没有转发历史、错误详情或测试发送入口。

## 按优先级排序的问题

P1表示应优先修复的核心行为、可靠性或凭据安全问题；P2表示重要的边界、交互、兼容或发布问题。编号不代表已在真机复现。

### F01 · P1 · 停止监控没有真正停止后续转发

位置：[SmsForwardService.kt:98](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:98)；[SmsBroadcastReceiver.kt:48](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsBroadcastReceiver.kt:48)；[BootReceiver.kt:18](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/BootReceiver.kt:18)；[main.dart:94](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:94)。

触发与影响：先保存一条启用规则，点击“停止监控”，再收到一条匹配短信。静态接收器没有检查用户停用状态，仍会启动服务并转发；重新打开 App、重启手机也会无条件启动。用户以为已暂停的短信仍可能被发送到外部。

修复方向：持久化一个“用户启用监控”状态，所有入口和处理入口共同检查；区分用户主动关闭与系统回收。停止时取消恢复任务。

### F02 · P1 · 前台服务类型不适合无限期后台监控，并破坏 Android 15+ 开机恢复

位置：[AndroidManifest.xml:23](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/AndroidManifest.xml:23)；[SmsForwardService.kt:63](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:63)；[BootReceiver.kt:18](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/BootReceiver.kt:18)；[build.gradle.kts:40](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/build.gradle.kts:40)。

触发与影响：服务声明 specialUse|dataSync，调用两参数 startForeground 使用 manifest 中的类型。现有构建合并清单显示 targetSdkVersion=36。对 Android 15+ 且 target>=35，dataSync 后台运行受每24小时累计6小时限制，且禁止从 BOOT_COMPLETED 启动该类型。代码没有 onTimeout 处理，开机接收器也没有捕获启动异常。长期运行可能被终止并触发异常，开机恢复不可靠。此项为代码与官方规则交叉核对，未进行真机6小时运行。

修复方向：按真实短信跨设备转发场景重新评估 remoteMessaging 等服务类型；按系统版本显式选择适用类型，处理启动失败与超时，不要通过叠加 specialUse 期待绕过 dataSync 限制。若采用 specialUse，应补充用途 property。

### F03 · P1 · 划掉任务后的精确闹钟存在未捕获的权限异常

位置：[SmsForwardService.kt:110](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:110)；[AndroidManifest.xml:3](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/AndroidManifest.xml:3)。

触发与影响：onTaskRemoved 直接执行 AlarmManager.setExact(PendingIntent)。清单没有精确闹钟权限，代码也没有 canScheduleExactAlarms 检查或异常处理。在 Android 12+、target>=31 且不具备相应授权或系统豁免的设备上，划掉任务可触发 SecurityException，反而终止进程。忽略电池优化可能构成部分系统上的豁免，因此不能说每台设备都会失败。

修复方向：优先移除为了500ms恢复而使用的精确闹钟；若确有适用需求，检查能力、处理失败，并使用适合后台前台服务恢复的方式。不要把精确闹钟作为常驻保证。

### F04 · P1 · 长短信按 PDU 片段分别匹配和转发

位置：[SmsBroadcastReceiver.kt:35](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsBroadcastReceiver.kt:35)；[SmsBroadcastReceiver.kt:43](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsBroadcastReceiver.kt:43)；[SmsForwardService.kt:203](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:203)。

触发与影响：一个 SMS_RECEIVED 广播中的多段短信被逐个构造成独立服务 Intent，没有拼接正文。例如关键词“验证码”跨片段边界时，完整短信本应命中却漏掉；无关键词限制时同一条长短信会变成多条残缺推送。

修复方向：在接收器中按同一逻辑短信组合片段后，统一做一次规则匹配和转发，并保留必要的时间、订阅信息。

### F05 · P1 · SMTP 授权码以可逆 Base64 写入日志

位置：[SmsForwardService.kt:358](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:358)；[SmsForwardService.kt:380](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:380)；[SmsForwardService.kt:384](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:384)。

触发与影响：sendCommand 会记录完整命令，而用户名和授权码也通过它发送。每次邮件登录都会把用户名与授权码的 Base64 形式写入 Logcat；Base64 不是加密。拥有日志访问能力的人或收集到的调试日志可还原凭据。

修复方向：AUTH 阶段只记录步骤和返回码，禁止记录凭据和任何可逆编码。生产构建也应关闭或脱敏这些调试日志。

### F06 · P1 · SMTP TLS 缺少服务器主机名校验

位置：[SmsForwardService.kt:333](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:333)。

触发与影响：手动创建的 SSLSocket 使用默认信任管理器校验证书链，但没有校验证书是否属于用户配置的 SMTP 主机。网络被劫持且对方具有系统信任的其他域名证书时，存在冒充服务器获取凭据和短信的风险。不是“信任所有证书”；缺失的是主机身份绑定。

修复方向：在发送 AUTH 前完成 TLS 握手和可靠的主机名验证，或使用正确配置的成熟 SMTP 实现。验证失败必须终止发送。

### F07 · P1 · HTTP 错误和业务拒绝也会被记为转发成功

位置：[SmsForwardService.kt:249](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:249)；[SmsForwardService.kt:294](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:294)；[SmsForwardService.kt:445](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:445)。

触发与影响：httpPost 对非2xx响应只是返回错误正文或“HTTP 状态码”字符串；调用方无条件打印成功。HTTP 2xx 中 PushPlus 的失败 code、钉钉的错误字段也没有解析。Token失效、限流、认证拒绝或服务器500时，会出现“成功”日志但实际没收到消息，且结果不回传界面。

修复方向：统一返回结构化发送结果，校验HTTP状态与通道业务码，将实际失败记录到可查看的状态中；至少提供测试发送和最近错误。

### F08 · P2 · 转发任务只在内存中执行，断网或进程终止会永久丢任务

位置：[SmsForwardService.kt:82](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:82)；[SmsForwardService.kt:107](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:107)；[SmsForwardService.kt:132](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:132)；[SmsForwardService.kt:239](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:239)。

触发与影响：收到短信后只启动协程，没有先落地任务、失败重试、任务恢复或完成确认。断网后仅写日志；服务被回收后 START_STICKY 只重建服务，不会重放已消费短信；onDestroy 还会取消协程。已接收但未完成发送的短信不能可靠补发。

修复方向：使用持久化待发送队列和明确的成功/失败状态，结合网络约束做有界重试；设计任务ID和去重。验证码要有过期策略，不能无限重试。

### F09 · P2 · 短信发送没有正确处理长内容、双卡选择和发送结果

位置：[SmsForwardService.kt:257](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:257)。

触发与影响：将附加“【验证码】来自…”前缀后的正文直接交给 sendTextMessage，没有 divideMessage / sendMultipartTextMessage。超出单条容量的消息缺乏可靠分段。也未选择具体subscription；双卡没有默认发送卡时可能失败。sentIntent 和 deliveryIntent 都是null，系统拒绝或运营商发送失败不会被真实确认，日志“已发送”只表示调用返回。

修复方向：显式分段发送，允许选择或明确解释默认SIM行为，使用发送结果回调；区分提交、发送成功和送达。

### F10 · P2 · 界面提示支持587/TLS，但 SMTP 实现只有隐式TLS直连

位置：[main.dart:328](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:328)；[SmsForwardService.kt:329](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:329)。

触发与影响：配置提示“465(SSL) 或 587(TLS)”，但所有端口都用 SSLSocket 直接连接。常规587服务器要求先建立SMTP会话、EHLO、STARTTLS后再升级连接，当前完全没有实现，因此用户按提示正确填写587仍可能握手失败或超时。

修复方向：配置明确的传输安全模式并实现STARTTLS，或暂时将界面限定为实际支持的隐式TLS并给出正确说明。

### F11 · P2 · SMTP 未填授权码也显示已配置，并允许保存邮箱规则

位置：[main.dart:288](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:288)；[main.dart:362](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:362)；[main.dart:715](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:715)；[SmsForwardService.kt:314](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:314)。

触发与影响：界面只检查host和user非空就显示绿色“SMTP已配置”，保存弹窗也不验证密码、端口范围和邮箱地址；原生发送却要求password非空。临时测试确认：只设置host和user、不设置password，界面标记已配置，而且邮箱规则仍可添加，实际执行会静默跳过。

修复方向：前后端共享一致的必填校验；区分“已填写”和“连通性验证成功”，提供测试发送结果。

### F12 · P2 · 一条损坏规则会让全部规则消失，随后保存会覆盖有效数据

位置：[main.dart:237](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:237)；[main.dart:253](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:253)；[SmsForwardService.kt:487](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:487)。

触发与影响：Flutter 和原生规则加载都用一个总try/catch包住整份列表，单项解析失败就整批失败。临时测试使用一条有效规则加一条坏JSON：页面显示“暂无规则”，随后新增规则会将原有有效规则一起覆盖。

修复方向：逐条解析并隔离坏项，明确提示加载异常，保留原始数据；在加载失败状态下阻止无提示的整表覆盖，并考虑schema版本和恢复备份。

### F13 · P2 · 号码规范化会改写匹配模式，某些条件退化为匹配全部

位置：[SmsForwardService.kt:203](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:203)；[SmsForwardService.kt:543](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:543)。

触发与影响：normalizePhone 会无条件删除任意号码或匹配表达式开头的86，且匹配函数将空pattern视为通配。用户填写来源“86”并选择包含或前缀匹配时，pattern被变成空串，所有来源都会命中；86123等服务号也会被改写。对完整国际号码的规范化不应直接用于任意子串表达式。

修复方向：区分完整号码与包含/前缀/后缀条件，按明确的国家区号格式规范化，避免非空输入变成通配条件；统一Dart和Kotlin的规范化约定。

### F14 · P2 · 服务状态和操作反馈可能与实际情况不一致

位置：[native_service_bridge.dart:12](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/native_service_bridge.dart:12)；[main.dart:149](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:149)；[main.dart:382](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:382)；[MainActivity.kt:60](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/MainActivity.kt:60)。

触发与影响：桥接层把异常吞成false，界面却忽略start/stop返回值，仍显示正在启动/停止；原生也在提交启动请求后立即返回true，没有确认onCreate成功。返回前台只刷新权限，不刷新服务状态。临时测试确认：startService=false仍出现启动提示；模拟后台服务停止后回到前台，页面仍显示运行中。

修复方向：区分正在切换、已确认运行、已停止和失败；处理返回值，恢复前台时刷新状态，必要时通过事件回传服务生命周期。

### F15 · P2 · 首页权限提示区域不可滚动，横屏/小高度窗口溢出

位置：[main.dart:792](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:792)；[main.dart:905](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:905)。

触发与影响：所有提示条放在同一固定Column中，只有规则列表Expanded可滚动。640×320逻辑像素、所有权限未授予且显示自启动提示时，临时测试稳定出现底部RenderFlex溢出17像素，提示和规则区域被挤出视窗。

修复方向：让整个页面内容可滚动或使用统一sliver布局；将服务状态、权限引导与规则列表共同纳入可用高度管理。

### F16 · P2 · 规则弹窗在放大字号时下拉框横向溢出

位置：[main.dart:534](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:534)；[main.dart:556](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:556)；[main.dart:573](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:573)。

触发与影响：下拉控件没有为长选项和放大字体提供足够的宽度适配。最终测试中320×640、默认字号正常，150%字号出现右侧RenderFlex溢出71像素。默认字号的最初异常受测试字体影响，经过中文回退字体复核后已排除，不能把它当作默认字号的确定缺陷。

修复方向：为Dropdown设置可伸展宽度和适当的文本换行/省略，验证无障碍字号、键盘出现后的滚动和横屏。

### F17 · P2 · SMTP 连接缺少连接超时，异常路径没有可靠关闭socket

位置：[SmsForwardService.kt:333](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:333)；[SmsForwardService.kt:436](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:436)；[SmsForwardService.kt:438](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:438)。

触发与影响：createSocket(host,port)在设置soTimeout之前建立连接，soTimeout只约束后续读，不是TCP连接超时。授权失败、协议错误或读取超时时，catch路径不会close，只有成功路径关闭；重复失败可积累连接和阻塞任务。

修复方向：使用显式connect timeout，分别约束握手与读写，并通过use/finally保证socket和流在所有路径关闭；让失败传回任务系统。

### F18 · P2 · release 构建仍使用 debug 签名

位置：[build.gradle.kts:50](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/build.gradle.kts:50)。

触发与影响：buildTypes.release.signingConfig直接引用debug配置。若当前代码直接用于正式发行，签名身份依赖各开发机debug keystore，可能导致跨机器构建无法覆盖升级，也不适合作为长期发行身份。此项针对发布准备，不表示现有安装包已被替换或泄露。

修复方向：准备明确的release签名与安全的密钥管理，保持更新签名连续；发布前检查最终包签名，而不是仅检查构建模式。

## 其他需要处理或明确的事项

- SMTP正文使用Base64.NO_WRAP（[SmsForwardService.kt:408](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt:408)），没有MIME要求的76字符折行。较长短信可能形成超过SMTP行长限制的内容；中文From显示名也没有做encoded-word编码。建议使用合规MIME构造。

- Token和SMTP授权码目前保存在普通SharedPreferences（[main.dart:365](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:365)、[main.dart:733](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:733)）。没有看到敏感配置加密及专门的备份排除规则。文件属于应用私有存储，并非其他普通App可任意读取；仍应为备份、调试导出和设备迁移明确保护方式。

- [main.dart:259](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart:259)及SMTP保存忽略SharedPreferences setter返回的bool；内存状态先改，保存失败没有回滚。部分失败只返回false而不抛异常时，当前catch不会提示。SMTP四项也逐个写入，服务并发读取时可能得到中间配置。

- 第一命中规则策略是否符合产品预期需要明确；首页应说明优先级并允许排序，否则靠前的宽泛规则会遮挡后面的精细规则。不能仅凭“只转发一次”就将其判定为程序错误。

- 钉钉仅实现access_token参数，没有secret、timestamp、sign相关字段或算法；要求签名的机器人不在当前实现覆盖范围内。需要按目标机器人安全配置验证，并在UI解释支持的配置。

- 短信转发没有自发自收/两设备互转循环保护；配置到本机号码或相互转发时有重复发送的风险。需要明确处理策略，并结合真实号码与运营商验证。

- 一次10分钟WakeLock不是长期后台或每次投递的唤醒保证。服务常驻、CPU唤醒、Doze网络可用性和任务持久化应分别设计，不能通过常驻图标推断短信已送达。

- 自启动提示在点击“去设置”时就被永久标记已处理，未验证用户是否真正开启，后续不再提示。通知权限文案也应准确：POST_NOTIFICATIONS不是启动前台服务的硬性前提。

- 弹窗创建的TextEditingController没有统一dispose；SMTP异步预填还可能覆盖已开始输入的内容。规则卡片24像素InkWell缺少足够触达区域和语义说明。

- 规则卡片未显示目标邮箱/号码/群等信息，不利于检查实际发送位置；也无成功次数、失败原因、配置测试入口。属于可观察性和操作体验缺口。

- 旧SmsReceiver、重复的Dart/Kotlin规则模型、依靠中文字符串分发类型增加维护成本；README仍是Flutter模板。跨平台目录存在并不等于短信业务已经跨平台实现，当前只确认Android有原生桥接实现。

## 验证记录

- flutter analyze --no-pub：通过，输出“No issues found!”。静态分析通过不证明业务语义、平台服务约束或网络投递正确。

- flutter test --no-pub（现有测试）：因OneDrive上的test/widget_test.dart读取超时退出70，No tests ran；不是现有测试断言失败。

- 临时Flutter测试：8项，6项通过、2项失败。2项正常显示检查通过；4项异常行为确认测试通过，代表确认了缺陷，不能当作产品行为正确；2项布局完整性断言失败。

| 临时测试 | 结果 | 证明范围 |
|---|---|---|
| 390×844首页、存在一条规则 | 通过 | 常规竖屏渲染基线 |
| 640×320首页、全部权限提示 | 失败 | 底部溢出17逻辑像素 |
| 320×640规则编辑、默认字号 | 通过 | 默认字号窄屏本轮没有稳定溢出 |
| 不填写SMTP授权码仍可创建邮箱规则 | 异常行为确认通过 | F11 |
| 有效规则加坏JSON，再新增规则 | 异常行为确认通过 | F12有效数据被覆盖 |
| 服务启动返回false | 异常行为确认通过 | F14仍出现启动提示 |
| 服务后台停止后恢复前台 | 异常行为确认通过 | F14状态保持过时 |
| 320×640规则编辑、150%字号 | 失败 | 右侧溢出71逻辑像素 |

临时测试直接引用项目的MyApp/HomeScreen和规则模型，并模拟权限、SharedPreferences与MethodChannel；没有模拟短信原生投递或第三方服务。为使headless环境显示中文，在测试包装层为现有主题增加中文fallback，加载Roboto、MaterialIcons和本机中文字体；截图用于布局核对，字体度量和系统边距仍以真机为准。

最终测试输出：[logs/audit-widget-tests-2026-11-04.txt](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/audit-widget-tests-2026-11-04.txt)。临时测试脚本：[/private/tmp/ez_sms_audit/audit_widget_test.dart](/private/tmp/ez_sms_audit/audit_widget_test.dart)。

布局截图：

- [正常竖屏首页](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/audit-home-390x844.png)

- [横屏全部权限提示](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/audit-home-640x320.png)

- [320宽默认字号规则弹窗](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/audit-rule-320x640.png)

- [320宽150%字号规则弹窗](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/audit-rule-320x640-text150.png)

## 官方规则核对来源

- F02：[Android前台服务类型](https://developer.android.com/develop/background-work/services/fgs/service-types)、[前台服务超时](https://developer.android.com/develop/background-work/services/fgs/timeout)、[Service API](https://developer.android.com/reference/android/app/Service)。

- F03：[精确闹钟调度及权限](https://developer.android.com/develop/background-work/services/alarms)。

- F04与旧系统PDU解析：[SmsMessage](https://developer.android.com/reference/android/telephony/SmsMessage)、[Telephony.Sms.Intents](https://developer.android.com/reference/android/provider/Telephony.Sms.Intents)。旧实现createFromPdu未传format，Android24–32的3gpp2等格式还需针对性验证。

- F06：[Android网络TLS安全，直接使用SSLSocket的警告](https://developer.android.com/privacy-and-security/security-ssl)。

- F07：[PushPlus官方业务返回码](https://www.pushplus.plus/doc/guide/code.html)。

- F09：[SmsManager API](https://developer.android.com/reference/android/telephony/SmsManager.html)。

- F10：[RFC8314，587 STARTTLS与465隐式TLS](https://www.rfc-editor.org/info/rfc8314/)。

- 邮件格式：[RFC2045，MIME Base64折行](https://www.rfc-editor.org/info/rfc2045/)。

- 通知文案：[Android通知运行时权限](https://developer.android.com/develop/ui/compose/notifications/notification-permission)。

## 建议修复顺序

先修F01–F07，解决停止失效、平台生命周期、长短信接收和凭据/结果正确性；接着处理持久化投递、短信发送与SMTP配置/协议；再修规则容错、状态同步和布局；正式分发前完成release签名检查。修复后需要覆盖Android12、14、15/16及目标厂商系统的真机收信、长短信、双卡、断网恢复、划掉任务、重启和长期后台验证。
