// 后台收消息时发系统通知。
//
// 平台支持：
//   - Android: flutter_local_notifications（完整支持）
//   - Windows: flutter_local_notifications 不支持 Windows，当前跳过（用户说「如 Windows 可实现也可以加」，留 TODO）
//
// 行为：app 在前台时不发通知（UI 自己会显示）；后台/最小化时收到消息发通知。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _available = false;

  static const String _channelId = 'lan_broadcast_msg';
  static const String _channelName = '局域网喊话消息';
  static const String _channelDesc = '后台收到的局域网喊话消息通知';

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // flutter_local_notifications 18.x 支持 Android / iOS / macOS / Linux，不支持 Windows
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS && !Platform.isLinux) {
      _available = false;
      return;
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const linuxInit = LinuxInitializationSettings(defaultActionName: '打开');
    const settings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
      macOS: iosInit,
      linux: linuxInit,
    );

    final ok = await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onTap,
    );
    _available = ok ?? false;

    // Android 13+ 需要运行时请求 POST_NOTIFICATIONS 权限
    if (Platform.isAndroid) {
      try {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        await android?.requestNotificationsPermission();
      } catch (e) {
        debugPrint('NotificationService: request permission failed: $e');
      }
    }
  }

  void _onTap(NotificationResponse resp) {
    // 用户点通知打开 app，目前不需要做额外动作（app 会恢复到聊天页）
    debugPrint('Notification tapped: id=${resp.id}');
  }

  /// 显示一条消息通知。title 用发送者昵称，body 用消息内容。
  Future<void> showMessage({required String name, required String msg}) async {
    if (!_available) return;
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
      styleInformation: BigTextStyleInformation(''),
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails, macOS: iosDetails);

    // 用 name 的 hashCode 做 id（同一发送者的新消息会覆盖旧的，避免通知栏堆积）
    final id = name.hashCode & 0x7FFFFFFF;
    try {
      await _plugin.show(
        id,
        name.isEmpty ? '(匿名)' : name,
        msg,
        details,
      );
    } catch (e) {
      debugPrint('NotificationService.show failed: $e');
    }
  }
}
