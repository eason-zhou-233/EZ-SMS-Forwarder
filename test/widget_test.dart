import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sms_forwarder/main.dart';

const serviceChannel = MethodChannel('com.example.sms_forwarder/service');
const permissionChannel = MethodChannel(
  'flutter.baseflow.com/permissions/methods',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHome(
    WidgetTester tester, {
    List<String> rules = const [],
    List<String>? calls,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'forward_rules': rules});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      permissionChannel,
      (call) async => switch (call.method) {
        'requestPermissions' => {
          for (final permission in call.arguments as List) permission: 1,
        },
        'checkPermissionStatus' => 1,
        _ => true,
      },
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      serviceChannel,
      (call) async {
        calls?.add(call.method);
        return true;
      },
    );
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
  }

  testWidgets('首页启动使用恢复入口，不覆盖用户停用意图', (tester) async {
    final calls = <String>[];
    await pumpHome(tester, calls: calls);
    expect(calls.where((method) => method == 'ensureService'), hasLength(1));
    expect(calls, isNot(contains('startService')));
  });

  testWidgets('已保存的规则仍正常显示', (tester) async {
    await pumpHome(
      tester,
      rules: [
        jsonEncode(
          ForwardRule(
            name: '银行验证码',
            targetNumber: '95588',
            keyword: '验证码',
            dingTalkAccessToken: 'test-only',
          ).toJson(),
        ),
      ],
    );
    expect(find.text('规则名称: 银行验证码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('启动请求失败时不显示开启成功', (tester) async {
    await pumpHome(tester);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      serviceChannel,
      (call) async => false,
    );
    await tester.tap(find.byTooltip('停止监控'));
    await tester.pumpAndSettle();
    expect(find.textContaining('操作失败'), findsOneWidget);
    expect(find.text('后台监控已开启'), findsNothing);
  });

  testWidgets('返回前台刷新实际已停止的服务状态', (tester) async {
    await pumpHome(tester);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      serviceChannel,
      (call) async => false,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.textContaining('后台服务已停止'), findsOneWidget);
  });

  testWidgets('点击状态条查看投递错误和进程退出记录', (tester) async {
    await pumpHome(tester);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      serviceChannel,
      (call) async => call.method == 'getDiagnostics'
          ? <String, String>{
              'lastEvent': '钉钉群转发失败，将重试',
              'pendingCount': '1',
              'lastExitReason': '系统内存不足回收',
              'recentEvents': jsonEncode([
                {'time': 1793760000000, 'message': '后台服务已启动'},
              ]),
            }
          : true,
    );
    await tester.tap(find.textContaining('后台服务运行中'));
    await tester.pumpAndSettle();
    expect(find.text('后台运行记录'), findsOneWidget);
    expect(find.textContaining('钉钉群转发失败'), findsOneWidget);
    expect(find.textContaining('系统内存不足回收'), findsOneWidget);
    expect(find.textContaining('最近运行记录（新到旧）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('连续点击只提交一次服务切换', (tester) async {
    await pumpHome(tester);
    var starts = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      serviceChannel,
      (call) async {
        if (call.method == 'startService') {
          starts++;
          return true;
        }
        return false;
      },
    );
    final button = find.byTooltip('停止监控');
    await tester.tap(button);
    await tester.pump();
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(starts, 1);
  });
}
