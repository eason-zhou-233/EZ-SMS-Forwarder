import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 【修改点】：导入路径改为 another_telephony
import 'package:another_telephony/telephony.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

// 【极其重要】：后台处理函数必须添加 @pragma('vm:entry-point')
// 确保在 AOT 编译模式下该函数不会被移除
@pragma('vm:entry-point')
Future<void> onBackgroundMessage(SmsMessage message) async {
  debugPrint("后台收到短信: ${message.address} - ${message.body}");
  await processSms(message);
}

// 核心处理逻辑：读取配置并判断是否转发
Future<void> processSms(SmsMessage message) async {
  final prefs = await SharedPreferences.getInstance();
  final targetNumber = prefs.getString('targetNumber') ?? '';
  final keyword = prefs.getString('keyword') ?? '';
  final pushToken = prefs.getString('pushToken') ?? '';

  // 如果没有配置完整，就不处理
  if (targetNumber.isEmpty || pushToken.isEmpty) return;

  final sender = message.address ?? '';
  final content = message.body ?? '';

  // 逻辑判断：发送号码匹配，并且短信内容包含关键词
  if (sender.contains(targetNumber) &&
      (keyword.isEmpty || content.contains(keyword))) {
    final url = Uri.parse('http://www.pushplus.plus/send');
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': pushToken,
          'title': '【自动转发】收到来自 $sender 的短信',
          'content': content,
          'channel': "wechat", // 如果需要推送到微信，可以改为 "wechat"
        }),
      );
      final Map<String, dynamic> responseData = jsonDecode(response.body);
      if (response.statusCode == 200) {
        debugPrint("PushPlus 接口调用成功！响应内容: $responseData");
      } else {
        debugPrint("PushPlus 接口调用异常: ${response.body}");
      }
    } catch (e) {
      debugPrint("网络请求失败: $e");
    }
  }
}

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '短信自动转发 (another_telephony 版)',
      theme: ThemeData(
        useMaterial3: true,
        primaryColor: Colors.deepPurple,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const ConfigScreen(),
    );
  }
}

class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _numberController = TextEditingController();
  final _keywordController = TextEditingController();
  final _tokenController = TextEditingController();

  // 【修改点】：同样使用 another_telephony 的单例
  final Telephony telephony = Telephony.instance;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _initSmsListener();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _numberController.text = prefs.getString('targetNumber') ?? '';
      _keywordController.text = prefs.getString('keyword') ?? '';
      _tokenController.text = prefs.getString('pushToken') ?? '';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('targetNumber', _numberController.text.trim());
    await prefs.setString('keyword', _keywordController.text.trim());
    await prefs.setString('pushToken', _tokenController.text.trim());

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('✅ 配置已保存，转发监听中...')));
    }
  }

  void _initSmsListener() async {
    // 申请短信权限
    bool? permissionsGranted = await telephony.requestPhoneAndSmsPermissions;
    if (permissionsGranted == true) {
      telephony.listenIncomingSms(
        onNewMessage: (SmsMessage message) {
          debugPrint("前台收到短信: ${message.body}");
          processSms(message);
        },
        onBackgroundMessage: onBackgroundMessage,
      );
    } else {
      debugPrint("用户拒绝了短信权限");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('短信转发配置'),
        centerTitle: true,
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            const Icon(
              Icons.forward_to_inbox,
              size: 64,
              color: Colors.deepPurple,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _numberController,
              decoration: const InputDecoration(
                labelText: '指定发件号码 (如: 10086)',
                hintText: '留空表示转发所有号码',
                prefixIcon: Icon(Icons.phone_android),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _keywordController,
              decoration: const InputDecoration(
                labelText: '触发关键词 (如: 验证码)',
                hintText: '留空表示转发该号码所有短信',
                prefixIcon: Icon(Icons.key),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'PushPlus Token',
                prefixIcon: Icon(Icons.token),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _saveSettings,
                icon: const Icon(Icons.save),
                label: const Text('保存并启动', style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
