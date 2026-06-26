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

// --- 转发方式常量 ---
const String _forwardTypePushPlus = 'PushPlus推送';
const String _forwardTypeSms = '短信发送';
const String _forwardTypeDingTalk = '钉钉群';

// --- 规则模型 ---
class ForwardRule {
  String targetNumber;
  String keyword;
  String numberMatchType;
  String keywordMatchType;
  String forwardType; // 转发方式
  // PushPlus 配置
  String pushPlusToken;
  String pushPlusTopic;
  String pushPlusTo;
  // 短信转发 配置
  String smsTargetNumber;
  // 钉钉群 配置
  String dingTalkAccessToken;

  ForwardRule({
    required this.targetNumber,
    required this.keyword,
    this.numberMatchType = '精确匹配',
    this.keywordMatchType = '包含',
    this.forwardType = _forwardTypeSms,
    this.pushPlusToken = '',
    this.pushPlusTopic = '',
    this.pushPlusTo = '',
    this.smsTargetNumber = '',
    this.dingTalkAccessToken = '',
  });

  Map<String, dynamic> toJson() => {
    'targetNumber': targetNumber,
    'keyword': keyword,
    'numberMatchType': numberMatchType,
    'keywordMatchType': keywordMatchType,
    'forwardType': forwardType,
    'pushPlusToken': pushPlusToken,
    'pushPlusTopic': pushPlusTopic,
    'pushPlusTo': pushPlusTo,
    'smsTargetNumber': smsTargetNumber,
    'dingTalkAccessToken': dingTalkAccessToken,
  };

  factory ForwardRule.fromJson(Map<String, dynamic> json) => ForwardRule(
    targetNumber: json['targetNumber'] ?? '',
    keyword: json['keyword'] ?? '',
    numberMatchType: json['numberMatchType'] ?? '精确匹配',
    keywordMatchType: json['keywordMatchType'] ?? '包含',
    forwardType: json['forwardType'] ?? _forwardTypeSms,
    pushPlusToken: json['pushPlusToken'] ?? '',
    pushPlusTopic: json['pushPlusTopic'] ?? '',
    pushPlusTo: json['pushPlusTo'] ?? '',
    smsTargetNumber: json['smsTargetNumber'] ?? '',
    dingTalkAccessToken: json['dingTalkAccessToken'] ?? '',
  );
}

// ------------------- 后台通知插件（单次初始化） -------------------
FlutterLocalNotificationsPlugin? _bgFlutterLocalNotificationsPlugin;

Future<void> _ensureBgNotificationsInitialized() async {
  if (_bgFlutterLocalNotificationsPlugin != null) return;
  _bgFlutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings settings = InitializationSettings(
    android: androidSettings,
  );
  await _bgFlutterLocalNotificationsPlugin!.initialize(settings: settings);
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
      foregroundServiceTypes: [
        AndroidForegroundType.specialUse,
        AndroidForegroundType.dataSync,
      ],
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

  WidgetsFlutterBinding.ensureInitialized();

  // 在 onStart 中一次性初始化通知插件
  await _ensureBgNotificationsInitialized();

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
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await processSms(message);
}

// ------------------- 核心转发逻辑 -------------------

/// 标准化手机号码：去掉国际区号(+86等)、空格、短横线等
String _normalizePhone(String phone) {
  // 去掉所有空格、短横线、括号
  var result = phone.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  // 去掉国际区号前缀：先去掉 + 号，再去掉已知的中国区号 86
  if (result.startsWith('+')) {
    result = result.substring(1);
  }
  if (result.startsWith('86')) {
    result = result.substring(2);
  }
  return result;
}

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
  await _ensureBgNotificationsInitialized();

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();

  final List<String> rulesJson = prefs.getStringList('forward_rules') ?? [];
  final sender = message.address ?? '';
  final content = message.body ?? '';

  // 标准化后的号码，用于号码比较
  final normalizedSender = _normalizePhone(sender);

  debugPrint('========== 短信匹配日志 ==========');
  debugPrint('原始发件人: "$sender"');
  debugPrint('标准化发件人: "$normalizedSender"');
  debugPrint('短信内容: "$content"');
  debugPrint('当前规则数: ${rulesJson.length}');

  for (String ruleStr in rulesJson) {
    final rule = ForwardRule.fromJson(jsonDecode(ruleStr));
    final normalizedTarget = _normalizePhone(rule.targetNumber);

    debugPrint('---');
    debugPrint('规则-原始号码: "${rule.targetNumber}"');
    debugPrint('规则-标准化号码: "$normalizedTarget"');
    debugPrint('规则-号码匹配模式: ${rule.numberMatchType}');
    debugPrint('规则-关键词: "${rule.keyword}"');
    debugPrint('规则-关键词匹配模式: ${rule.keywordMatchType}');
    debugPrint('规则-转发方式: ${rule.forwardType}');

    final numberMatch = _isMatch(
      normalizedSender,
      normalizedTarget,
      rule.numberMatchType,
    );
    final keywordMatch = _isMatch(content, rule.keyword, rule.keywordMatchType);

    debugPrint('号码匹配结果: $numberMatch');
    debugPrint('关键词匹配结果: $keywordMatch');

    if (numberMatch && keywordMatch) {
      debugPrint('>>> 规则匹配成功，开始转发: ${rule.forwardType} <<<');
      await _executeForward(rule, sender, content);
      debugPrint('==================================');
      return;
    }
  }
  debugPrint('>>> 无匹配规则，未转发 <<<');
  debugPrint('==================================');
}

Future<void> _executeForward(
  ForwardRule rule,
  String sender,
  String content,
) async {
  switch (rule.forwardType) {
    case _forwardTypePushPlus:
      await _sendToPushPlus(rule, sender, content);
      break;
    case _forwardTypeSms:
      await _sendBySms(rule, sender, content);
      break;
    case _forwardTypeDingTalk:
      await _sendToDingTalk(rule, sender, content);
      break;
    default:
      debugPrint("未知的转发方式: ${rule.forwardType}");
  }
}

Future<void> _sendToPushPlus(
  ForwardRule rule,
  String sender,
  String content,
) async {
  if (rule.pushPlusToken.isEmpty) {
    debugPrint("转发跳过: 未配置 PushPlus Token");
    return;
  }
  try {
    final body = <String, dynamic>{
      'token': rule.pushPlusToken,
      'title': '【验证码】来自 $sender',
      'content': content,
      'channel': "wechat",
    };
    if (rule.pushPlusTopic.isNotEmpty) {
      body['topic'] = rule.pushPlusTopic;
    }
    if (rule.pushPlusTo.isNotEmpty) {
      body['to'] = rule.pushPlusTo;
    }
    final response = await http
        .post(
          Uri.parse('https://www.pushplus.plus/send'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 10));
    debugPrint("PushPlus转发成功: ${response.body}");
  } catch (e) {
    debugPrint("PushPlus转发失败: $e");
  }
}

Future<void> _sendBySms(ForwardRule rule, String sender, String content) async {
  if (rule.smsTargetNumber.isEmpty) {
    debugPrint("转发跳过: 未配置短信目标号码");
    return;
  }
  try {
    await Telephony.instance.sendSms(
      to: rule.smsTargetNumber,
      message: '【验证码】来自 $sender\n$content',
    );
    debugPrint("短信转发已发送");
  } catch (e) {
    debugPrint("短信转发失败: $e");
  }
}

Future<void> _sendToDingTalk(
  ForwardRule rule,
  String sender,
  String content,
) async {
  if (rule.dingTalkAccessToken.isEmpty) {
    debugPrint("转发跳过: 未配置钉钉 Access Token");
    return;
  }
  try {
    final url = Uri.parse(
      'https://oapi.dingtalk.com/robot/send?access_token=${rule.dingTalkAccessToken}',
    );
    final title = '短信转发 - 来自 $sender';
    final text =
        '**【验证码】**  \n'
        '**发件人：** $sender  \n'
        '**内容：** $content';
    final response = await http
        .post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'msgtype': 'markdown',
            'markdown': {'title': title, 'text': text},
          }),
        )
        .timeout(const Duration(seconds: 10));
    debugPrint("钉钉转发成功: ${response.body}");
  } catch (e) {
    debugPrint("钉钉转发失败: $e");
  }
}

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
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
        inputDecorationTheme: const InputDecorationTheme(
          labelStyle: TextStyle(fontSize: 14),
          hintStyle: TextStyle(fontSize: 13),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<ForwardRule> _rules = [];
  bool _isBatteryOptimized = false;
  bool _isServiceRunning = false;
  bool _smsPermissionGranted = false;
  bool _notificationPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 从后台（包括设置页）返回前台时重新检查权限
      _checkSmsPermission();
      _checkNotificationPermission();
      _checkBatteryOptimization();
    }
  }

  Future<void> _initApp() async {
    try {
      final statuses = await [
        Permission.sms,
        Permission.notification,
        Permission.phone,
        Permission.ignoreBatteryOptimizations,
      ].request();

      if (statuses[Permission.notification]?.isDenied == true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('请授予通知权限以确保后台服务正常运行'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }

      _checkSmsPermission();
      _checkNotificationPermission();

      Telephony.instance.listenIncomingSms(
        onNewMessage: (msg) => processSms(msg),
        onBackgroundMessage: backHandler,
      );

      _checkServiceStatus();
      _checkBatteryOptimization();
      _loadRules();
    } catch (e) {
      debugPrint("初始化失败: $e");
    }
  }

  Future<void> _checkServiceStatus() async {
    try {
      final isRunning = await FlutterBackgroundService().isRunning();
      if (mounted) {
        setState(() {
          _isServiceRunning = isRunning;
        });
      }
    } catch (e) {
      debugPrint("检查服务状态失败: $e");
    }
  }

  Future<void> _checkSmsPermission() async {
    final status = await Permission.sms.status;
    if (mounted) {
      setState(() => _smsPermissionGranted = status.isGranted);
    }
  }

  Future<void> _openSmsSettings() async {
    await openAppSettings();
    _checkSmsPermission();
  }

  Future<void> _checkNotificationPermission() async {
    final status = await Permission.notification.status;
    if (mounted) {
      setState(() => _notificationPermissionGranted = status.isGranted);
    }
  }

  Future<void> _checkBatteryOptimization() async {
    try {
      var status = await Permission.ignoreBatteryOptimizations.status;
      if (mounted) {
        setState(() => _isBatteryOptimized = !status.isGranted);
      }
    } catch (e) {
      debugPrint("检查电池优化状态失败: $e");
    }
  }

  Future<void> _loadRules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String> rulesJson = prefs.getStringList('forward_rules') ?? [];
      if (mounted) {
        setState(() {
          _rules = rulesJson
              .map((e) => ForwardRule.fromJson(jsonDecode(e)))
              .toList();
        });
      }
    } catch (e) {
      debugPrint("加载规则失败: $e");
    }
  }

  Future<void> _saveRules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> rulesJson = _rules
          .map((e) => jsonEncode(e.toJson()))
          .toList();
      await prefs.setStringList('forward_rules', rulesJson);
    } catch (e) {
      debugPrint("保存规则失败: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存规则失败'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _toggleService() async {
    try {
      final service = FlutterBackgroundService();
      bool isRunning = await service.isRunning();

      if (isRunning) {
        service.invoke("stopService");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("后台监控服务已停止"),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      } else {
        await service.startService();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("后台监控服务已启动"),
              backgroundColor: Colors.green,
            ),
          );
        }
      }

      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        _checkServiceStatus();
      }
    } catch (e) {
      debugPrint("切换服务失败: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
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
    _showRuleDialog();
  }

  void _showRuleDialog({int? editIndex}) {
    final isEdit = editIndex != null;
    final existingRule = isEdit ? _rules[editIndex] : null;

    final numCtrl = TextEditingController(
      text: existingRule?.targetNumber ?? '',
    );
    final keyCtrl = TextEditingController(text: existingRule?.keyword ?? '');
    String numberMatchType = existingRule?.numberMatchType ?? '精确匹配';
    String keywordMatchType = existingRule?.keywordMatchType ?? '包含';
    String forwardType = existingRule?.forwardType ?? _forwardTypeSms;
    // 各转发方式的配置
    final ppTokenCtrl = TextEditingController(
      text: existingRule?.pushPlusToken ?? '',
    );
    final ppTopicCtrl = TextEditingController(
      text: existingRule?.pushPlusTopic ?? '',
    );
    final ppToCtrl = TextEditingController(
      text: existingRule?.pushPlusTo ?? '',
    );
    final smsTargetCtrl = TextEditingController(
      text: existingRule?.smsTargetNumber ?? '',
    );
    final dtTokenCtrl = TextEditingController(
      text: existingRule?.dingTalkAccessToken ?? '',
    );

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: Text(isEdit ? '编辑转发规则' : '新增转发规则'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // --- 监听号码 ---
                TextField(
                  controller: numCtrl,
                  decoration: const InputDecoration(labelText: '监听号码（留空匹配所有）'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: numberMatchType,
                  decoration: const InputDecoration(
                    labelText: '号码匹配模式',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: '包含', child: Text('包含')),
                    DropdownMenuItem(value: '精确匹配', child: Text('精确匹配')),
                    DropdownMenuItem(value: '以此开头', child: Text('以此开头')),
                    DropdownMenuItem(value: '以此结尾', child: Text('以此结尾')),
                  ],
                  onChanged: (val) =>
                      setDialogState(() => numberMatchType = val!),
                ),
                const SizedBox(height: 16),
                // --- 关键词 ---
                TextField(
                  controller: keyCtrl,
                  decoration: const InputDecoration(labelText: '关键词（留空匹配所有）'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: keywordMatchType,
                  decoration: const InputDecoration(
                    labelText: '关键词匹配模式',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: '包含', child: Text('包含')),
                    DropdownMenuItem(value: '精确匹配', child: Text('精确匹配')),
                    DropdownMenuItem(value: '以此开头', child: Text('以此开头')),
                    DropdownMenuItem(value: '以此结尾', child: Text('以此结尾')),
                  ],
                  onChanged: (val) =>
                      setDialogState(() => keywordMatchType = val!),
                ),
                const SizedBox(height: 16),
                // --- 转发方式 ---
                DropdownButtonFormField<String>(
                  initialValue: forwardType,
                  decoration: const InputDecoration(
                    labelText: '转发方式',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: _forwardTypeSms,
                      child: Text('短信发送'),
                    ),
                    DropdownMenuItem(
                      value: _forwardTypeDingTalk,
                      child: Text('钉钉群'),
                    ),
                    DropdownMenuItem(
                      value: _forwardTypePushPlus,
                      child: Text('PushPlus微信公众号推送'),
                    ),
                  ],
                  onChanged: (val) => setDialogState(() => forwardType = val!),
                ),
                const SizedBox(height: 16),
                // --- PushPlus 配置 ---
                if (forwardType == _forwardTypePushPlus) ...[
                  TextField(
                    controller: ppTokenCtrl,
                    decoration: const InputDecoration(
                      labelText: 'PushPlus Token（必填）',
                      hintText: '在 pushplus.plus 官网获取',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ppTopicCtrl,
                    decoration: const InputDecoration(
                      labelText: 'topic（群组编码，选填）',
                      hintText: 'PushPlus群组编码，用于群发',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ppToCtrl,
                    decoration: const InputDecoration(
                      labelText: 'to（好友令牌，选填）',
                      hintText: '多个令牌用英文逗号分隔',
                    ),
                  ),
                ],
                // --- 短信发送 配置 ---
                if (forwardType == _forwardTypeSms)
                  TextField(
                    controller: smsTargetCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: '目标号码（必填）',
                      hintText: '短信将转发到此号码',
                    ),
                  ),
                // --- 钉钉群 配置 ---
                if (forwardType == _forwardTypeDingTalk)
                  TextField(
                    controller: dtTokenCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Access Token（必填）',
                      hintText: '钉钉群机器人的 access_token',
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                final newRule = ForwardRule(
                  targetNumber: numCtrl.text.trim(),
                  keyword: keyCtrl.text.trim(),
                  numberMatchType: numberMatchType,
                  keywordMatchType: keywordMatchType,
                  forwardType: forwardType,
                  pushPlusToken: ppTokenCtrl.text.trim(),
                  pushPlusTopic: ppTopicCtrl.text.trim(),
                  pushPlusTo: ppToCtrl.text.trim(),
                  smsTargetNumber: smsTargetCtrl.text.trim(),
                  dingTalkAccessToken: dtTokenCtrl.text.trim(),
                );
                setState(() {
                  if (isEdit) {
                    _rules[editIndex] = newRule;
                  } else {
                    _rules.add(newRule);
                  }
                });
                _saveRules();
                Navigator.pop(context);
              },
              child: Text(isEdit ? '保存' : '添加'),
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
          if (!_notificationPermissionGranted)
            Container(
              width: double.infinity,
              color: Colors.orange.shade100,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.info, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      "通知权限未授予，后台服务可能无法正常运行",
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await openAppSettings();
                      _checkNotificationPermission();
                    },
                    child: const Text("去设置", style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          if (!_smsPermissionGranted)
            Container(
              width: double.infinity,
              color: Colors.red.shade100,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber, color: Colors.red, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      "短信权限未授予，无法读取和发送短信。请在设置中开启短信读取和发送权限，并确保开启「通知类短信」读取权限（通常在隐私设置中），以确保能够正常读取验证码等通知类短信。",
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: _openSmsSettings,
                    child: const Text("去设置", style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          if (_isBatteryOptimized)
            Container(
              color: Colors.orange.shade100,
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  const Icon(Icons.info, color: Colors.orange),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      "请将电池优化策略设为「无限制」以防止后台运行时被系统关闭进程",
                      style: TextStyle(fontSize: 12),
                    ),
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
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      rule.targetNumber.isEmpty
                                          ? "监听号码: 所有号码"
                                          : "监听号码: ${rule.targetNumber}",
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      "号码匹配规则: ${rule.numberMatchType}",
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    Text(
                                      "关键词匹配规则: ${rule.keywordMatchType}",
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    Text(
                                      rule.keyword.isEmpty
                                          ? "关键词: 所有内容"
                                          : "关键词: ${rule.keyword}",
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      "转发方式: ${rule.forwardType}",
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  InkWell(
                                    onTap: () =>
                                        _showRuleDialog(editIndex: index),
                                    child: const Icon(
                                      Icons.edit_outlined,
                                      color: Colors.blue,
                                      size: 24,
                                    ),
                                  ),
                                  const SizedBox(height: 26),
                                  InkWell(
                                    onTap: () => _confirmDelete(index),
                                    child: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.red,
                                      size: 24,
                                    ),
                                  ),
                                ],
                              ),
                            ],
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
