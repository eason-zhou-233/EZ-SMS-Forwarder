import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:another_telephony/telephony.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// --- 全局常量配置 ---
const String myPushToken = "a6cbb3c5cfe448d78175479f6610c836";

// --- 规则模型 ---
class ForwardRule {
  String targetNumber;
  String keyword;
  String matchType;

  ForwardRule({
    required this.targetNumber,
    required this.keyword,
    this.matchType = '包含',
  });

  Map<String, dynamic> toJson() => {
    'targetNumber': targetNumber,
    'keyword': keyword,
    'matchType': matchType,
  };
  factory ForwardRule.fromJson(Map<String, dynamic> json) => ForwardRule(
    targetNumber: json['targetNumber'] ?? '',
    keyword: json['keyword'] ?? '',
    matchType: json['matchType'] ?? '包含',
  );
}

// ------------------- 后台服务初始化 -------------------

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'forward_service_channel',
    '短信转发监控',
    description: '此通知确保转发服务在后台持续运行',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'forward_service_channel',
      initialNotificationTitle: '短信转发助手',
      initialNotificationContent: '监控运行中...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async => true;

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // 在后台进程中必须初始化 Flutter 引擎绑定，否则后续调用 SharedPreferences 会直接崩溃！
  WidgetsFlutterBinding.ensureInitialized();

  final Telephony telephony = Telephony.instance;

  telephony.listenIncomingSms(
    onNewMessage: (msg) => processSms(msg),
    onBackgroundMessage: backHandler,
  );

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  Timer.periodic(const Duration(seconds: 10), (timer) async {
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: "短信转发助手",
          content: "正在后台运行...",
        );
      }
    }
  });
}

@pragma('vm:entry-point')
Future<void> backHandler(SmsMessage message) async {
  await processSms(message);
}

// ------------------- 核心转发逻辑 -------------------

bool _isMatch(String fullText, String pattern, String type) {
  if (pattern.isEmpty) return true;
  final text = fullText.trim();
  final p = pattern.trim();
  switch (type) {
    case '精确匹配':
      return text == p;
    case '以此开头':
      return text.startsWith(p);
    case '以此结尾':
      return text.endsWith(p);
    case '包含':
    default:
      return text.contains(p);
  }
}

Future<void> processSms(SmsMessage message) async {
  // 1. 获取通知插件实例
  final flnp = FlutterLocalNotificationsPlugin();
  // --- 【后台初始化】 ---
  // 必须显式指定图标，通常使用 Android 项目自带的 @mipmap/ic_launcher
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );

  // 在后台进程中重新初始化一次
  await flnp.initialize(settings: initializationSettings);
  // ----------------------------
  // // 生成一个相对唯一的ID
  // final int notificationId = DateTime.now().millisecondsSinceEpoch % 100000;
  // // 【调试断点 1】：证明系统确实把短信交给了我们的代码
  // await flnp.show(
  //   id: notificationId, // 随机ID避免覆盖
  //   title: '⚡ 成功拦截到底层短信',
  //   body: '来自: ${message.address}',
  //   notificationDetails: const NotificationDetails(
  //     android: AndroidNotificationDetails(
  //       'forward_service_channel',
  //       '短信转发监控',
  //       importance: Importance.max,
  //       priority: Priority.high,
  //       showWhen: true,
  //     ),
  //   ),
  // );

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload(); // 强制刷新隔离区缓存

  final List<String> rulesJson = prefs.getStringList('forward_rules') ?? [];
  final sender = message.address ?? '';
  final content = message.body ?? '';

  // // 【调试断点 2】：确认当前读取到了几条规则
  // await flnp.show(
  //   id: DateTime.now().millisecond + 1,
  //   title: '🔍 正在匹配规则',
  //   body: '当前内存中共有 ${rulesJson.length} 条转发规则',
  //   notificationDetails: NotificationDetails(
  //     android: AndroidNotificationDetails(
  //       'forward_service_channel',
  //       '短信转发监控',
  //       importance: Importance.low,
  //     ),
  //   ),
  // );

  for (String ruleStr in rulesJson) {
    final rule = ForwardRule.fromJson(jsonDecode(ruleStr));
    if (_isMatch(sender, rule.targetNumber, rule.matchType) &&
        _isMatch(content, rule.keyword, rule.matchType)) {
      // // 【调试断点 3】：规则匹配成功，准备发网路请求
      // await flnp.show(
      //   id: DateTime.now().millisecond + 2,
      //   title: '✅ 规则匹配成功',
      //   body: '准备推送到 PushPlus...',
      //   notificationDetails: NotificationDetails(
      //     android: AndroidNotificationDetails(
      //       'forward_service_channel',
      //       '短信转发监控',
      //       importance: Importance.high,
      //     ),
      //   ),
      // );
      await _sendToPushPlus(sender, content);
      break;
    }
  }
}

Future<void> _sendToPushPlus(String sender, String content) async {
  try {
    final response = await http.post(
      Uri.parse('http://www.pushplus.plus/send'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'token': myPushToken,
        'title': '【自动转发】来自 $sender',
        'content': content,
        'channel': "wechat",
      }),
    );
    debugPrint("转发成功: ${response.body}");
  } catch (e) {
    debugPrint("转发失败: $e");
  }
}

// ------------------- UI 部分 -------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ForwardRule> _rules = [];
  bool _isBatteryOptimized = false;
  bool _isServiceRunning = false;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    // 1. 依次检查并申请所有必要权限
    Map<Permission, PermissionStatus> statuses = await [
      Permission.sms,
      Permission.notification, // 必须申请通知权限，否则调试通知看不见
      Permission.phone,
      Permission.ignoreBatteryOptimizations,
    ].request();

    // 2. 在主进程也注册一遍监听（让后台监听生效的关键“握手”）
    Telephony.instance.listenIncomingSms(
      onNewMessage: (msg) => processSms(msg),
      onBackgroundMessage: backHandler,
    );

    _checkServiceStatus();
    _checkBatteryOptimization();
    _loadRules();
  }

  Future<void> _checkServiceStatus() async {
    final isRunning = await FlutterBackgroundService().isRunning();
    setState(() {
      _isServiceRunning = isRunning;
    });
  }

  Future<void> _initPermissions() async {
    await [Permission.sms, Permission.notification, Permission.phone].request();
  }

  Future<void> _checkBatteryOptimization() async {
    var status = await Permission.ignoreBatteryOptimizations.status;
    setState(() => _isBatteryOptimized = !status.isGranted);
  }

  Future<void> _loadRules() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> rulesJson = prefs.getStringList('forward_rules') ?? [];
    setState(() {
      _rules = rulesJson
          .map((e) => ForwardRule.fromJson(jsonDecode(e)))
          .toList();
    });
  }

  Future<void> _saveRules() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> rulesJson = _rules.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList('forward_rules', rulesJson);
  }

  void _toggleService() async {
    final service = FlutterBackgroundService();
    bool isRunning = await service.isRunning();

    if (isRunning) {
      service.invoke("stopService");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("后台监控服务已停止"),
          backgroundColor: Colors.redAccent,
        ),
      );
    } else {
      await service.startService();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("后台监控服务已启动"),
          backgroundColor: Colors.green,
        ),
      );
    }

    Future.delayed(const Duration(milliseconds: 500), () {
      _checkServiceStatus();
    });
  }

  void _confirmDelete(int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除这条规则吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setState(() => _rules.removeAt(index));
              _saveRules();
              Navigator.pop(context);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showAddRuleDialog() {
    final numCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    String selectedType = '包含';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('新增转发规则'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: numCtrl,
                decoration: const InputDecoration(labelText: '监听号码'),
              ),
              TextField(
                controller: keyCtrl,
                decoration: const InputDecoration(labelText: '关键词'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: selectedType,
                decoration: const InputDecoration(
                  labelText: '匹配模式',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: '包含', child: Text('包含')),
                  DropdownMenuItem(value: '精确匹配', child: Text('精确匹配')),
                  DropdownMenuItem(value: '以此开头', child: Text('以此开头')),
                  DropdownMenuItem(value: '以此结尾', child: Text('以此结尾')),
                ],
                onChanged: (val) => setDialogState(() => selectedType = val!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(
                  () => _rules.add(
                    ForwardRule(
                      targetNumber: numCtrl.text.trim(),
                      keyword: keyCtrl.text.trim(),
                      matchType: selectedType,
                    ),
                  ),
                );
                _saveRules();
                Navigator.pop(context);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('短信转发助手'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // IconButton(
          //   icon: const Icon(Icons.send),
          //   onPressed: () => _sendToPushPlus("调试测试", "手动触发网络检查"),
          // ),
          IconButton(
            icon: Icon(
              _isServiceRunning ? Icons.stop_circle : Icons.play_circle_filled,
              color: _isServiceRunning ? Colors.red : Colors.green,
              size: 28,
            ),
            onPressed: _toggleService,
            tooltip: _isServiceRunning ? "停止监控" : "开启监控",
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isBatteryOptimized)
            Container(
              color: Colors.orange.shade100,
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  const Icon(Icons.info, color: Colors.orange),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text("建议开启保活以防服务中断", style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () async {
                      await Permission.ignoreBatteryOptimizations.request();
                      _checkBatteryOptimization();
                    },
                    child: const Text("去设置"),
                  ),
                ],
              ),
            ),
          Container(
            width: double.infinity,
            color: _isServiceRunning
                ? Colors.green.shade50
                : Colors.grey.shade200,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              _isServiceRunning ? "● 监控服务运行中" : "○ 监控服务已停止",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _isServiceRunning ? Colors.green : Colors.grey,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: _rules.isEmpty
                ? const Center(child: Text("暂无规则，点击下方 + 号添加"))
                : ListView.builder(
                    itemCount: _rules.length,
                    itemBuilder: (context, index) {
                      final rule = _rules[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: ListTile(
                          title: Text(
                            rule.targetNumber.isEmpty
                                ? "所有号码"
                                : "号码: ${rule.targetNumber}",
                          ),
                          subtitle: Text(
                            "模式: ${rule.matchType} | 关键词: ${rule.keyword}",
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            onPressed: () => _confirmDelete(index),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddRuleDialog,
        child: const Icon(Icons.add),
      ),
    );
  }
}
