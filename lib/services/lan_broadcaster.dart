// UDP 组播局域网喊话服务（跨平台抽象层）。
//
// 约定：
//   组播地址 239.255.255.155 : 1556
//   编码：JSON 字符串 + UTF-8，结构：{"name":"xxx","msg":"xxx"}
//
// 平台实现：
//   - Android：[LanBroadcastService]（Kotlin Foreground Service）持有 UDP socket。
//     原因：Flutter app 进入后台时 Dart isolate 会被 Flutter engine 暂停，
//     即使持有 MulticastLock，Dart 侧 RawDatagramSocket 的 listen 回调也不会触发，
//     导致后台完全收不到消息。把 socket 移到 Kotlin Service 后，
//     Service 不受 Dart isolate 暂停影响，可持续接收。
//     Dart 通过 MethodChannel 调用 start/stop/send/setForeground，
//     通过 EventChannel 接收 message / network / ready 事件。
//   - 其他平台（Windows/Linux/macOS/iOS）：Dart RawDatagramSocket 实现，
//     桌面后台不强制暂停，原逻辑保留。
//
// 网络健康检测理念（用户确认的流程）：
//   - 平时无人发消息时组播地址保持安静，不主动发探测包/心跳。
//   - 两套互补的断网检测机制（都不在组播地址上产生额外流量）：
//     1. 系统级 API（Android 端 ConnectivityManager.NetworkCallback / 桌面端
//        connectivity_plus）：网络切换/断开重连时立即重新 join，并推
//        NetworkChangeEvent 给 UI 居中提示。
//     2. 回显检测（Dart 实现端）：发消息后依赖组播回环收到自己的消息 = 网络正常；
//        2 秒内没收到回显 = 组播成员资格可能失效 → 重新 join。
//
// 发送后不本地插入消息，UI 显示完全依赖组播回环（multicastLoopback）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/lan_message.dart';

/// 网络变化事件（推给 UI 用于在消息列表插入居中系统提示）。
class NetworkChangeEvent {
  /// 变化原因：'available' / 'lost' / 'changed' / 'default-available' / 'default-lost'
  /// / 'first-event'（Dart 端实现首次触发占位）等。UI 不强依赖具体值。
  final String reason;
  final DateTime timestamp;

  const NetworkChangeEvent._({required this.reason, required this.timestamp});

  @override
  String toString() => 'NetworkChangeEvent($reason @ $timestamp)';
}

abstract class LanBroadcaster {
  static const String multicastIp = '239.255.255.155';
  static const int port = 1556;

  factory LanBroadcaster() {
    if (Platform.isAndroid) {
      return _AndroidLanBroadcaster();
    }
    return _DartLanBroadcaster();
  }

  Stream<LanMessage> get onMessage;
  Stream<NetworkChangeEvent> get onNetworkChanged;
  bool get isActive;

  Future<void> start();
  Future<void> send(LanMessage message);
  Future<void> close();
  void dispose();

  /// 由 ChatPage 在 didChangeAppLifecycleState 调用，通知 Service 当前 Flutter
  /// app 是否在前台。Android 端 Service 据此决定是否在收到消息时同时发本地通知。
  /// 非 Android 平台空操作。
  void setForeground(bool foreground) {}
}

// ===========================================================================
// Android：通过 MethodChannel / EventChannel 与 Kotlin Foreground Service 通信
// ===========================================================================
class _AndroidLanBroadcaster implements LanBroadcaster {
  static const MethodChannel _control = MethodChannel('lan_broadcast/control');
  static const EventChannel _events = EventChannel('lan_broadcast/events');

  // implements 不继承父类静态成员，这里重新指向父类同名常量，
  // 方便下面 send() 实现里直接用裸名 multicastIp / port。
  static const String multicastIp = LanBroadcaster.multicastIp;
  static const int port = LanBroadcaster.port;

  final _msgController = StreamController<LanMessage>.broadcast();
  final _netController = StreamController<NetworkChangeEvent>.broadcast();
  StreamSubscription? _eventSub;
  bool _started = false;
  bool _disposed = false;

  @override
  bool get isActive => _started && !_disposed;

  @override
  Stream<LanMessage> get onMessage => _msgController.stream;

  @override
  Stream<NetworkChangeEvent> get onNetworkChanged => _netController.stream;

  @override
  Future<void> start() async {
    if (_disposed) throw StateError('LanBroadcaster disposed');
    if (_started) return;
    _started = true;

    _eventSub = _events.receiveBroadcastStream().listen(
      (dynamic raw) {
        if (raw is! Map) return;
        final type = raw['type'];
        if (type == 'message') {
          final name = (raw['name'] as String?) ?? '';
          final msg = (raw['msg'] as String?) ?? '';
          if (name.isEmpty && msg.isEmpty) return;
          _msgController.add(LanMessage(name: name, msg: msg));
        } else if (type == 'network') {
          _netController.add(NetworkChangeEvent._(
            reason: (raw['reason'] as String?) ?? 'unknown',
            timestamp: DateTime.now(),
          ));
        }
        // 'ready' 事件不需要 UI 处理
      },
      onError: (e) => debugPrint('LanBroadcaster(Android) event error: $e'),
    );

    try {
      await _control.invokeMethod('start');
    } catch (e) {
      debugPrint('LanBroadcaster(Android) start failed: $e');
      rethrow;
    }
  }

  @override
  Future<void> send(LanMessage message) async {
    if (_disposed) throw StateError('LanBroadcaster disposed');
    if (!_started) throw StateError('LanBroadcaster not started');
    // Android 发送路径：直接用 Dart RawDatagramSocket 发，不走 Service.trySend()。
    //
    // 原因：Service 持有的 MulticastSocket 绑定在 0.0.0.0:1556 接收端口，
    //   Android 上 MulticastSocket.send() 经常因为 outgoing interface 不明确
    //   抛异常（NetworkUnreachableException 等），fallback 临时 DatagramSocket
    //   仍可能失败 → "service return false"。
    //
    // 改为 Dart 自己用临时 RawDatagramSocket（绑定任意 ephemeral 端口）直接
    //   send 组播，OS 自动选 outgoing interface，绕开 Service IPC 的所有坑。
    //   Service 的 socket 仍负责 1556 端口接收（含回环），收到后通过
    //   EventChannel 推回 Dart → UI 显示自己刚发的消息（回环路径保持）。
    final bytes = utf8.encode(jsonEncode(message.toJson()));
    RawDatagramSocket? ds;
    try {
      ds = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      ds.multicastLoopback = true; // 让本机 Service socket 也能收到（回环）
      ds.multicastHops = 64;
      final sent = ds.send(bytes, InternetAddress(multicastIp), port);
      if (sent == 0) {
        throw const OSError('UDP send failed (0 bytes sent)');
      }
    } finally {
      try { ds?.close(); } catch (_) {}
    }
  }

  @override
  Future<void> close() async {
    // Android：Service 继续运行（后台保活），不主动 stop
  }

  @override
  void setForeground(bool foreground) {
    if (_disposed) return;
    try {
      _control.invokeMethod('setForeground', {'foreground': foreground});
    } catch (e) {
      debugPrint('LanBroadcaster(Android) setForeground failed: $e');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _eventSub?.cancel();
    _eventSub = null;
    try {
      _control.invokeMethod('stop');
    } catch (e) {
      debugPrint('LanBroadcaster(Android) stop failed: $e');
    }
    _msgController.close();
    _netController.close();
  }
}

// ===========================================================================
// 桌面 / iOS / Linux / macOS：Dart RawDatagramSocket 实现（原逻辑保留）
// ===========================================================================
class _DartLanBroadcaster implements LanBroadcaster {
  /// 发消息后等待回显的超时时间。正常组播回环 <10ms，2 秒足够判断断网。
  static const Duration _echoTimeout = Duration(seconds: 2);

  // 抽象类静态常量别名：implements 不继承静态成员，重新指向父类同名常量，
  // 这样下面的实现代码可以无前缀直接用 multicastIp / port。
  static const String multicastIp = LanBroadcaster.multicastIp;
  static const int port = LanBroadcaster.port;

  RawDatagramSocket? _socket;
  final _msgController = StreamController<LanMessage>.broadcast();
  final _netController = StreamController<NetworkChangeEvent>.broadcast();
  bool _disposed = false;

  // 机制 1：系统级网络变化事件流（不产生组播流量，只读系统状态）
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _connectivityFirstEvent = true;

  // 机制 2：回显检测（发消息后等组播回环，超时则重新 join）
  String? _pendingEchoHash;
  Timer? _echoTimer;

  // 重新 join 的互斥标志（两套机制共用，防止并发 restart）
  bool _restarting = false;

  @override
  bool get isActive => _socket != null && !_disposed;

  @override
  Stream<LanMessage> get onMessage => _msgController.stream;

  @override
  Stream<NetworkChangeEvent> get onNetworkChanged => _netController.stream;

  /// 绑定 UDP 端口并加入组播。可以重复调用（之前的 socket 会被关掉复用）。
  @override
  Future<void> start() async {
    if (_disposed) throw StateError('LanBroadcaster disposed');
    await _closeSocket();

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    socket.multicastLoopback = true; // 回环：本机发的组播消息回到自己，用于回显检测 + UI 显示
    socket.multicastHops = 64;

    final groupAddr = InternetAddress(multicastIp);
    int joined = 0;
    for (final iface in await _listIPv4Interfaces()) {
      try {
        socket.joinMulticast(groupAddr, iface);
        joined++;
      } catch (_) {
        // 虚拟网卡等接口 join 失败很正常，忽略即可
      }
    }
    debugPrint('LanBroadcaster: joined multicast on $joined interface(s)');

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final msg = _decode(datagram.data);
      if (msg == null) return;
      // 回显检测：收到的消息匹配待确认 hash 则清除超时（网络正常）
      if (_pendingEchoHash != null && _messageHash(msg) == _pendingEchoHash) {
        _pendingEchoHash = null;
        _echoTimer?.cancel();
      }
      _msgController.add(msg);
    });

    _socket = socket;
    _listenConnectivity();
  }

  Future<void> _closeSocket() async {
    final s = _socket;
    _socket = null;
    if (s != null) {
      try {
        s.close();
      } catch (_) {}
    }
  }

  @override
  Future<void> send(LanMessage message) async {
    if (_disposed) throw StateError('LanBroadcaster disposed');
    final s = _socket;
    if (s == null) throw StateError('LanBroadcaster not started');

    final bytes = utf8.encode(jsonEncode(message.toJson()));
    final sent = s.send(bytes, InternetAddress(multicastIp), port);
    if (sent == 0) throw const OSError('UDP send failed (0 bytes)');

    // 启动回显检测：2 秒内 socket 收到匹配的回环消息则正常，否则重新 join
    _pendingEchoHash = _messageHash(message);
    _echoTimer?.cancel();
    _echoTimer = Timer(_echoTimeout, () {
      if (_pendingEchoHash == null || _disposed || _restarting) return;
      debugPrint('LanBroadcaster: echo timeout (no loopback), rejoining multicast');
      _pendingEchoHash = null;
      _restarting = true;
      () async {
        try {
          await start();
        } catch (e) {
          debugPrint('LanBroadcaster: restart failed: $e');
        } finally {
          _restarting = false;
        }
      }();
    });
  }

  @override
  Future<void> close() => _closeSocket();

  @override
  void setForeground(bool foreground) {
    // 桌面 / iOS / macOS / Linux：Flutter engine 不强制暂停 isolate，
    // 无需把前后台状态通知给原生端。
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _echoTimer?.cancel();
    _closeSocket();
    _msgController.close();
    _netController.close();
  }

  // ----------------------------- internal -----------------------------

  /// 机制 1：监听系统网络变化事件流（Wi-Fi/有线切换、连接断开等）。
  /// 只读系统状态，不在组播地址上产生流量。变化时立即重新 join +
  /// 推 NetworkChangeEvent 给 UI 居中提示。
  void _listenConnectivity() {
    _connectivitySub?.cancel();
    _connectivityFirstEvent = true;
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (_restarting || _disposed) return;
      // 跳过第一次事件（listen 时会立即收到当前状态，不代表网络变化）
      if (_connectivityFirstEvent) {
        _connectivityFirstEvent = false;
        return;
      }
      final reason = results.isEmpty ? 'unknown' : results.first.toString();
      _netController.add(NetworkChangeEvent._(
        reason: reason,
        timestamp: DateTime.now(),
      ));
      debugPrint('LanBroadcaster: connectivity changed -> $results, rejoining');
      _restarting = true;
      () async {
        try {
          await start();
        } catch (e) {
          debugPrint('LanBroadcaster: restart failed: $e');
        } finally {
          _restarting = false;
        }
      }();
    });
  }

  /// 消息匹配用的 hash（name + msg 拼接，足够区分回显）
  static String _messageHash(LanMessage m) => '${m.name}\u0000${m.msg}';

  static Future<List<NetworkInterface>> _listIPv4Interfaces() async {
    final result = <NetworkInterface>[];
    try {
      for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
        includeLoopback: false,
      )) {
        result.add(iface);
      }
    } catch (_) {}
    return result;
  }

  static LanMessage? _decode(List<int> data) {
    try {
      final str = utf8.decode(data, allowMalformed: false);
      final json = jsonDecode(str);
      if (json is Map<String, dynamic>) return LanMessage.fromJson(json);
    } catch (_) {}
    return null;
  }
}
