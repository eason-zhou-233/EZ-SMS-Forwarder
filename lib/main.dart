import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'native_service_bridge.dart';

// --- 转发方式常量 ---
const String _forwardTypePushPlus = 'PushPlus推送';
const String _forwardTypeSms = '短信发送';
const String _forwardTypeDingTalk = '钉钉群';
const String _forwardTypeEmail = '邮箱';

// --- SMTP 存储 Key ---
const String _smtpKeyHost = 'smtp_host';
const String _smtpKeyPort = 'smtp_port';
const String _smtpKeyUser = 'smtp_user';
const String _smtpKeyPassword = 'smtp_password';

// --- 规则模型 ---
class ForwardRule {
  String targetNumber;
  String keyword;
  String numberMatchType;
  String keywordMatchType;
  String forwardType; // 转发方式
  bool enabled; // 是否启用
  // PushPlus 配置
  String pushPlusToken;
  String pushPlusTopic;
  String pushPlusTo;
  // 短信转发 配置
  String smsTargetNumber;
  // 钉钉群 配置
  String dingTalkAccessToken;
  // 邮箱转发 配置
  String emailTarget;

  ForwardRule({
    required this.targetNumber,
    required this.keyword,
    this.numberMatchType = '精确匹配',
    this.keywordMatchType = '包含',
    this.forwardType = _forwardTypeDingTalk,
    this.enabled = true,
    this.pushPlusToken = '',
    this.pushPlusTopic = '',
    this.pushPlusTo = '',
    this.smsTargetNumber = '',
    this.dingTalkAccessToken = '',
    this.emailTarget = '',
  });

  Map<String, dynamic> toJson() => {
    'targetNumber': targetNumber,
    'keyword': keyword,
    'numberMatchType': numberMatchType,
    'keywordMatchType': keywordMatchType,
    'forwardType': forwardType,
    'enabled': enabled,
    'pushPlusToken': pushPlusToken,
    'pushPlusTopic': pushPlusTopic,
    'pushPlusTo': pushPlusTo,
    'smsTargetNumber': smsTargetNumber,
    'dingTalkAccessToken': dingTalkAccessToken,
    'emailTarget': emailTarget,
  };

  factory ForwardRule.fromJson(Map<String, dynamic> json) => ForwardRule(
    targetNumber: json['targetNumber'] ?? '',
    keyword: json['keyword'] ?? '',
    numberMatchType: json['numberMatchType'] ?? '精确匹配',
    keywordMatchType: json['keywordMatchType'] ?? '包含',
    forwardType: json['forwardType'] ?? _forwardTypeDingTalk,
    enabled: json['enabled'] ?? true,
    pushPlusToken: json['pushPlusToken'] ?? '',
    pushPlusTopic: json['pushPlusTopic'] ?? '',
    pushPlusTo: json['pushPlusTo'] ?? '',
    smsTargetNumber: json['smsTargetNumber'] ?? '',
    dingTalkAccessToken: json['dingTalkAccessToken'] ?? '',
    emailTarget: json['emailTarget'] ?? '',
  );
}

// ========================
// 注意：SMS 监听、规则匹配、转发逻辑已全部迁移至
// Android 原生 SmsForwardService (ForegroundService)
// Flutter 端仅负责 UI 配置和通过 MethodChannel 控制服务
// ========================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动原生前台服务（内部会处理开机自启、划掉自恢复等）
  await NativeServiceBridge.startService();
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
  bool _showAutoStartTip = true;
  // SMTP 全局配置
  bool _smtpConfigured = false;

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

      // SMS 监听已由原生 SmsForwardService 负责，Flutter 端不再直接监听

      _checkServiceStatus();
      _checkBatteryOptimization();
      _loadRules();
      _loadAutoStartTip();
      _checkSmtpConfig();
    } catch (e) {
      debugPrint("初始化失败: $e");
    }
  }

  Future<void> _checkServiceStatus() async {
    try {
      final isRunning = await NativeServiceBridge.isServiceRunning();
      if (mounted) {
        setState(() {
          _isServiceRunning = isRunning;
        });
      }
    } catch (e) {
      debugPrint("检查服务状态失败: $e");
      // 回退：假设服务在运行
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
      // 通知原生 Service 规则已更新
      await NativeServiceBridge.notifyRulesUpdated();
    } catch (e) {
      debugPrint("保存规则失败: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存规则失败'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _loadAutoStartTip() async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool('auto_start_tip_dismissed') ?? false;
    if (mounted) {
      setState(() => _showAutoStartTip = !dismissed);
    }
  }

  Future<void> _dismissAutoStartTip() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_start_tip_dismissed', true);
    if (mounted) {
      setState(() => _showAutoStartTip = false);
    }
  }

  Future<void> _checkSmtpConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_smtpKeyHost) ?? '';
    final user = prefs.getString(_smtpKeyUser) ?? '';
    if (mounted) {
      setState(() => _smtpConfigured = host.isNotEmpty && user.isNotEmpty);
    }
  }

  void _showSmtpDialog() {
    final hostCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '465');
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();

    // 预填已有配置
    SharedPreferences.getInstance().then((prefs) {
      hostCtrl.text = prefs.getString(_smtpKeyHost) ?? '';
      final port = prefs.getInt(_smtpKeyPort);
      if (port != null) portCtrl.text = port.toString();
      userCtrl.text = prefs.getString(_smtpKeyUser) ?? '';
      passCtrl.text = prefs.getString(_smtpKeyPassword) ?? '';
    });

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SMTP发件邮箱配置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: hostCtrl,
                decoration: const InputDecoration(
                  labelText: 'SMTP服务器地址',
                  hintText: '如 smtp.qq.com',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: portCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '端口',
                  hintText: '465(SSL) 或 587(TLS)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: userCtrl,
                decoration: const InputDecoration(
                  labelText: '发件邮箱账号',
                  hintText: '如 123456@qq.com',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'SMTP授权码',
                  hintText: '邮箱生成的授权码，非登录密码',
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
            onPressed: () async {
              final navigator = Navigator.of(context);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(_smtpKeyHost, hostCtrl.text.trim());
              await prefs.setInt(
                _smtpKeyPort,
                int.tryParse(portCtrl.text.trim()) ?? 465,
              );
              await prefs.setString(_smtpKeyUser, userCtrl.text.trim());
              await prefs.setString(_smtpKeyPassword, passCtrl.text.trim());
              navigator.pop();
              _checkSmtpConfig();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleService() async {
    try {
      bool isRunning = await NativeServiceBridge.isServiceRunning();

      if (isRunning) {
        await NativeServiceBridge.stopService();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text("正在停止后台服务"),
              backgroundColor: Colors.redAccent,
              duration: const Duration(seconds: 1),
            ),
          );
        }
      } else {
        await NativeServiceBridge.startService();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text("正在启动后台服务"),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 1),
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
    String forwardType = existingRule?.forwardType ?? _forwardTypeDingTalk;
    final ruleEnabled = existingRule?.enabled ?? true;
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
    final emailCtrl = TextEditingController(
      text: existingRule?.emailTarget ?? '',
    );
    final smtpReady = _smtpConfigured;

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
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: numCtrl,
                        decoration: const InputDecoration(
                          labelText: '来源号码（留空匹配所有）',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.contacts_outlined, size: 22),
                      tooltip: '从通讯录选择',
                      onPressed: () async {
                        final picked = await NativeServiceBridge.pickContact();
                        if (picked != null && picked.isNotEmpty) {
                          numCtrl.text = picked;
                        }
                      },
                    ),
                  ],
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
                      value: _forwardTypeDingTalk,
                      child: Text('钉钉群'),
                    ),
                    DropdownMenuItem(
                      value: _forwardTypeEmail,
                      child: Text('邮箱转发'),
                    ),
                    DropdownMenuItem(
                      value: _forwardTypePushPlus,
                      child: Text('PushPlus微信公众号推送'),
                    ),
                    DropdownMenuItem(
                      value: _forwardTypeSms,
                      child: Text('短信转发'),
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
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: smsTargetCtrl,
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                labelText: '目标号码（必填）',
                                hintText: '短信将转发到此号码',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.contacts_outlined, size: 22),
                            tooltip: '从通讯录选择',
                            onPressed: () async {
                              final picked =
                                  await NativeServiceBridge.pickContact();
                              if (picked != null && picked.isNotEmpty) {
                                smsTargetCtrl.text = picked;
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '⚠️ Android 系统限制：非默认短信应用发送短信时系统会弹出确认框，无法完全静默自动发送。',
                        style: TextStyle(fontSize: 11, color: Colors.red),
                      ),
                    ],
                  ),
                // --- 邮箱转发 配置 ---
                if (forwardType == _forwardTypeEmail)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: '目标邮箱（必填）',
                          hintText: '短信内容将发送到此邮箱',
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (!_smtpConfigured)
                        const Text(
                          '⚠️ 请先在 App 首页右上角配置全局 SMTP 发件参数',
                          style: TextStyle(fontSize: 11, color: Colors.red),
                        ),
                    ],
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
                // 验证必填项
                String? error;
                if (forwardType == _forwardTypePushPlus &&
                    ppTokenCtrl.text.trim().isEmpty) {
                  error = '请填写 PushPlus Token';
                } else if (forwardType == _forwardTypeSms &&
                    smsTargetCtrl.text.trim().isEmpty) {
                  error = '请填写目标手机号';
                } else if (forwardType == _forwardTypeDingTalk &&
                    dtTokenCtrl.text.trim().isEmpty) {
                  error = '请填写 Access Token';
                } else if (forwardType == _forwardTypeEmail) {
                  if (!smtpReady) {
                    error = '请先配置全局 SMTP 发件参数';
                  } else if (emailCtrl.text.trim().isEmpty) {
                    error = '请填写目标邮箱';
                  }
                }
                if (error != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(error),
                      backgroundColor: Colors.red,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                  return;
                }

                final newRule = ForwardRule(
                  targetNumber: numCtrl.text.trim(),
                  keyword: keyCtrl.text.trim(),
                  numberMatchType: numberMatchType,
                  keywordMatchType: keywordMatchType,
                  forwardType: forwardType,
                  enabled: ruleEnabled,
                  pushPlusToken: ppTokenCtrl.text.trim(),
                  pushPlusTopic: ppTopicCtrl.text.trim(),
                  pushPlusTo: ppToCtrl.text.trim(),
                  smsTargetNumber: smsTargetCtrl.text.trim(),
                  dingTalkAccessToken: dtTokenCtrl.text.trim(),
                  emailTarget: emailCtrl.text.trim(),
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
        title: const Text('EZ短信转发助手'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: Icon(
              _smtpConfigured ? Icons.email : Icons.email_outlined,
              color: _smtpConfigured ? Colors.green : Colors.grey,
            ),
            onPressed: _showSmtpDialog,
            tooltip: _smtpConfigured ? "SMTP已配置" : "配置SMTP邮箱发件",
          ),
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
          if (_showAutoStartTip)
            Container(
              color: Colors.blue.shade50,
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.blue, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      "请确保已在系统设置中开启「自启动」权限，否则重启手机后服务无法自动恢复。",
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await openAppSettings();
                      _dismissAutoStartTip();
                    },
                    child: const Text("去设置", style: TextStyle(fontSize: 12)),
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
              _isServiceRunning ? "● 后台服务运行中" : "○ 后台服务已停止",
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
                        color: rule.enabled
                            ? Colors.green.shade50
                            : Colors.grey.shade100,
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
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            rule.targetNumber.isEmpty
                                                ? "来源号码: 所有号码"
                                                : "来源号码: ${rule.targetNumber}",
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold,
                                              color: rule.enabled
                                                  ? null
                                                  : Colors.grey,
                                            ),
                                          ),
                                        ),
                                        if (!rule.enabled)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.orange.shade100,
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: const Text(
                                              '已暂停',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.orange,
                                              ),
                                            ),
                                          ),
                                      ],
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
                                  // 暂停/启用切换
                                  InkWell(
                                    onTap: () {
                                      setState(() {
                                        rule.enabled = !rule.enabled;
                                      });
                                      _saveRules();
                                    },
                                    child: Icon(
                                      rule.enabled
                                          ? Icons.pause_circle_outline
                                          : Icons.play_circle_outline,
                                      color: rule.enabled
                                          ? Colors.orange
                                          : Colors.green,
                                      size: 24,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  InkWell(
                                    onTap: () =>
                                        _showRuleDialog(editIndex: index),
                                    child: const Icon(
                                      Icons.edit_outlined,
                                      color: Colors.blue,
                                      size: 24,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
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
