import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 原生后台服务通信层
/// 通过 MethodChannel 与 Android 原生 SmsForwardService 通信
class NativeServiceBridge {
  static const MethodChannel _channel =
      MethodChannel('com.example.sms_forwarder/service');

  /// 启动原生前台服务
  static Future<bool> startService() async {
    try {
      final result = await _channel.invokeMethod('startService');
      return result == true;
    } catch (e) {
      // 忽略错误，服务可能已在运行
      return false;
    }
  }

  /// 停止原生前台服务
  static Future<bool> stopService() async {
    try {
      final result = await _channel.invokeMethod('stopService');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// 检查服务是否在运行
  static Future<bool> isServiceRunning() async {
    try {
      final result = await _channel.invokeMethod('isServiceRunning');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// 通知原生端规则已更新（无需重启服务）
  static Future<void> notifyRulesUpdated() async {
    try {
      await _channel.invokeMethod('rulesUpdated');
    } catch (e) {
      // 忽略
    }
  }
}

/// 向前兼容的工具函数，模拟原来的 SharedPreferences 数据存取
/// 原生端 SmsForwardService 会直接读取 SharedPreferences 文件
class SmsPreferences {
  static Future<List<String>> getRules() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('forward_rules') ?? [];
  }

  static Future<void> saveRules(List<String> rulesJson) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('forward_rules', rulesJson);
    // 通知原生端规则已更新
    await NativeServiceBridge.notifyRulesUpdated();
  }

  static Future<String> getString(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key) ?? '';
  }

  static Future<void> setString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  static Future<int> getInt(String key, {int defaultValue = 0}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(key) ?? defaultValue;
  }

  static Future<void> setInt(String key, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
  }
}
