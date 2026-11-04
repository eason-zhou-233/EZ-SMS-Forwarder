# 小米15后台转发可靠性修复记录

日期：2026-11-04（Asia/Shanghai）。目标设备：小米15，用户报告HyperOS 3.0.307.0；使用钉钉、PushPlus、邮箱，基本不用短信发送。

用户报告常驻通知有时消失，并出现漏转发、打开应用后恢复。没有读取过手机的历史退出信息，实际原因尚未确认；本轮修复已确认的代码风险并补充诊断，不能将代码风险直接等同于这台手机已经发生的退出原因。

## 已修改的行为

1. 前台服务改为remoteMessaging；Android14+显式传入对应类型，旧系统使用兼容路径。移除dataSync和specialUse声明，避免dataSync的后台时限及开机启动约束。此类型的官方用途为跨设备传递文本消息。
2. 明确stopWithTask=false，移除onTaskRemoved中无授权检查的精确闹钟。保留START_STICKY恢复机制、静态短信接收器和开机恢复；启动受限会记录原因，不再让异常直接从开机入口冒出。
3. 短信广播在返回前合并同来源的PDU片段、将完整正文持久化到应用私有运行存储，再请求启动服务。即使启动被拒绝，已入队任务仍在；服务下一次获准启动时恢复处理。
4. 服务内单个IO工作协程串行发送，直接等待网络/SMTP操作结束。HTTP非2xx以及PushPlus、钉钉业务拒绝都视为失败，避免启动一个额外协程后就当作处理完成。
5. 未确认完成的网络任务最多尝试6次（包含首次），重试间隔递增，最大5分钟；任务接收超过30分钟后不再补发。最多保留100条待发记录，达到容量时记录失败，不删除更早的记录；即使入队失败，广播入口也会尝试启动服务排空已有任务。
6. 尝试次数、下次时间和规则快照在发送前持久化。成功后删除任务；恢复时不会把旧短信重新匹配到后来新增的目标。规则修改、删除或暂停后，原规则的待发任务取消。
7. 唤醒锁改为每次实际发送时持有，最长3分钟并在finally释放，避免应用启动后空持10分钟的方式。它不是CPU永久不休眠或进程永不被杀的保证。
8. 用户主动停止时持久化停用状态并清除待发任务。App打开、开机广播与短信广播均尊重停用状态；用户主动开启才重新启用。
9. 首页恢复前台时刷新服务状态；服务切换防止重复点击并处理失败，不再将返回false当作成功。启动页面使用ensureService恢复入口。
10. 点击首页服务状态条可查看本次服务启动、最近收信、最近提交成功、待发数量、最近20条运行事件，以及Android11+由系统提供的上次进程退出原因。记录不保存短信正文或凭据；厂商不给原因时明确显示暂无记录。
11. SMTP发送失败会传回队列；连接有显式超时，TLS启用服务器主机名校验，异常路径释放连接。删除授权码Base64日志，并修正MIME正文折行与中文发件人编码。仍沿用原有隐式TLS协议，未在本轮增加587/STARTTLS支持。
12. 将原有计数器模板测试替换为6项与当前App对应的服务控制、规则显示和运行记录回归测试。没有增加项目脚本或工具文件；临时测试工具均位于/private/tmp/ez_sms_background_fix。

## 验证

- Flutter静态分析：修改业务代码后的检查通过；包含正式回归测试的最终结果见下方最终验证。
- Android原生Kotlin代码：使用Android36 API、Flutter嵌入接口和缓存依赖编译通过，只有原有getRunningServices弃用提示。
- JVM队列与HTTP业务检查16项通过：含消息恢复、写盘失败、并发入队、容量、过期删除、重试上限、目标快照，以及PushPlus/钉钉错误码和HTTP失败判定。HTTP使用测试连接，不连接真实平台。
- 本机SMTP/TLS检查4项通过：正常认证和长正文；受信任但主机名错误的证书在AUTH前被拒绝；535永久错误与421临时错误分类及异常关闭。只使用回环地址、临时测试证书和虚构凭据，测试进程自带信任设置，未修改系统证书库。测试中仅替代Android Base64，实际SMTP/TLS方法来自项目代码。
- 现有项目6项Flutter回归测试在隔离临时工程中全部通过；测试输入与项目文件相同。此前另有5项临时界面检查通过，并生成运行记录截图。
- 无真机耐久验证：尚未在用户手机安装、验证锁屏/重启、清理最近任务、24小时运行或真实第三方账号投递。Android Service生命周期和HyperOS清理行为不属于上述JVM检查的覆盖范围。

## 构建环境记录

原项目的完整构建阻塞在OneDrive中android/.gradle/8.14/executionHistory的RandomAccessFile读取上；检查线程栈后停止了本轮启动的Gradle进程，未删除原缓存。随后复制构建所需文件到系统临时目录进行干净构建。第一次隔离构建发现PyCharm自带Java运行时缺少jlink，已改用电脑上现有的Temurin JDK21（/Users/zyc/.sdkman/candidates/java/21.0.10-tem），未安装新的JDK，也未更改全局Flutter配置。

Git中另有大量100644→100755模式变更；本轮未批量恢复文件权限或重置无关文件。下列差异按修改前临时备份与当前内容比较，仅反映本轮编辑。

## 使用和边界

安装新包后打开一次，在小米系统中允许本App后台自启动，将应用省电策略设为无限制，并在最近任务中锁定应用。具体菜单以手机当前系统为准。

如果再次发现通知消失或漏转发，打开App后点击首页服务状态条查看后台运行记录，结合上次进程退出时间和原因判断。系统提供的原因可能很粗，不能只凭“终止信号”就确定是HyperOS清理。

本轮提高的是常驻和已接收短信的恢复能力，不能保证普通应用永不被系统结束。若系统阻止短信广播投递，本App还没有收到的短信不会进入队列；用户强行停止也不能保证自行恢复。

网络发送结果不确定时，重试存在重复投递可能，当前三个平台未实现端到端幂等。30分钟和6次是明确的补发上限，不是保证每条短信都成功送达。普通SharedPreferences中的敏感配置保护、规则容错、匹配表达式与其他界面边界仍在原审查报告范围内，本轮没有将其全部修复。

## 文件

- [test/widget_test.dart](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/test/widget_test.dart)
- [android/app/src/main/AndroidManifest.xml](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/AndroidManifest.xml)
- [android/app/src/main/kotlin/com/example/sms_forwarder/SmsBroadcastReceiver.kt](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsBroadcastReceiver.kt)
- [android/app/src/main/kotlin/com/example/sms_forwarder/MainActivity.kt](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/MainActivity.kt)
- [android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/SmsForwardService.kt)
- [android/app/src/main/kotlin/com/example/sms_forwarder/BootReceiver.kt](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/android/app/src/main/kotlin/com/example/sms_forwarder/BootReceiver.kt)
- [lib/native_service_bridge.dart](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/native_service_bridge.dart)
- [lib/main.dart](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/lib/main.dart)

- [修改差异](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/background-fix-2026-11-04.diff)
- [队列与HTTP检查输出](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/background-native-tests-2026-11-04.txt)
- [SMTP/TLS检查输出](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/background-smtp-tests-2026-11-04.txt)
- [运行记录界面截图](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/background-runtime-records-2026-11-04.png)
- [隔离APK构建日志](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/background-apk-build-isolated-2026-11-04.txt)

## 官方依据

- [前台服务类型：remoteMessaging与dataSync](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [dataSync后台超时](https://developer.android.com/develop/background-work/services/fgs/timeout)
- [小米15后台网络限制与无限制省电](https://www.mi.com/my/support/faq/details/KA-538010/)
- [Android SSLSocket主机名验证](https://developer.android.com/privacy-and-security/security-ssl)

## 最终验证与交付

- 最终Flutter静态分析通过：No issues found，包含现有项目的6项回归测试。
- 现有项目6项回归测试在干净临时工程执行通过；加上16项队列/HTTP检查与4项SMTP/TLS检查，共26项针对性检查通过。此前临时界面检查不重复计入该数量。
- 完整APK构建通过：使用Temurin JDK21，在隔离临时工程执行flutter build apk --debug --no-pub --target-platform android-arm64，最终assembleDebug用时23.8秒。包实际包含arm64-v8a、armeabi-v7a、x86_64，兼容小米15的ARM64架构。
- 比对了隔离工程与原项目lib、android/app/src/main中的最终源码，内容一致。
- APK签名验证通过：APK Signature Scheme v2，单一签名者；当前仍为debug签名，未改签名配置。
- 从实际APK解析清单确认：targetSdk36、minSdk24、FOREGROUND_SERVICE_REMOTE_MESSAGING、service type 0x200（remoteMessaging）、stopWithTask=false；没有dataSync前台服务声明。

测试APK：[app-background-fix-2026-11-04-debug.apk](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/build/app/outputs/flutter-apk/app-background-fix-2026-11-04-debug.apk)，78,058,727字节。

SHA-256：`934377f341135bb23918f9625ca11831e4c0ebf406cf7eaa545bc480447177cb`。

完整包信息：[background-apk-2026-11-04.json](/Users/zyc/Library/CloudStorage/OneDrive-个人/文档/个人开发/EZ-SMS-Forwarder/logs/background-apk-2026-11-04.json)。
