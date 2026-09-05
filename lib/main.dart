import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models/lan_message.dart';
import 'services/lan_broadcaster.dart';
import 'services/notification_service.dart';
import 'utils/user_palette.dart';

void main() {
  runApp(const LanBroadcastApp());
}

class LanBroadcastApp extends StatelessWidget {
  const LanBroadcastApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '局域网喊话',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F7DFF)),
        scaffoldBackgroundColor: const Color(0xFFF4F6FB),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3F7DFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF10131A),
      ),
      themeMode: ThemeMode.system,
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final LanBroadcaster _broadcaster = LanBroadcaster();
  final List<(_Entry entry, AnimationController anim)> _messages = [];
  final ScrollController _scroll = ScrollController();
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _inputCtrl = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final FocusNode _nameFocus = FocusNode();

  // 消息列表内存上限：满 1G 清理最早的内容
  static const int _maxBytes = 1024 * 1024 * 1024; // 1 GiB
  int _totalBytes = 0;

  // 昵称持久化（防抖保存）
  Timer? _nameSaveTimer;

  // app 生命周期：后台时 Kotlin Service 自动发本地通知，
  // Dart 端只需要在前后台切换时通知 Service。
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _broadcaster.onMessage.listen(_onMessage);
    _broadcaster.onNetworkChanged.listen(_onNetworkChanged);
    _broadcaster.start();
    _loadNickname();
    _nameCtrl.addListener(_onNameChanged);
    // 申请 POST_NOTIFICATIONS 权限（Android 13+），Kotlin Service 发通知也依赖它
    NotificationService().init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nameSaveTimer?.cancel();
    _broadcaster.dispose();
    for (final (_, a) in _messages) {
      a.dispose();
    }
    _scroll.dispose();
    _nameCtrl.dispose();
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    // 通知 Kotlin Service 当前是否在前台：后台时 Service 收到消息会同时发本地通知
    _broadcaster.setForeground(state == AppLifecycleState.resumed);
  }

  // ----------------------- 昵称持久化 -----------------------

  void _onNameChanged() {
    _nameSaveTimer?.cancel();
    _nameSaveTimer = Timer(const Duration(milliseconds: 500), _saveNickname);
  }

  Future<void> _loadNickname() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString('nickname');
      if (name != null && name.isNotEmpty && mounted) {
        _nameCtrl.text = name;
      }
    } catch (_) {}
  }

  Future<void> _saveNickname() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('nickname', _nameCtrl.text.trim());
    } catch (_) {}
  }

  /// 估算一条 entry 占用的字节数
  static int _entryBytes(_Entry e) {
    return switch (e) {
      _MsgEntry(:final message) =>
        utf8.encode(message.name).length + utf8.encode(message.msg).length + 16,
      _SysEntry(:final text) => utf8.encode(text).length + 16,
    };
  }

  void _onMessage(LanMessage m) {
    if (m.name.isEmpty && m.msg.isEmpty) return;
    if (!mounted) return;

    // Android 端：Kotlin Service 自己根据 isAppInForeground 决定是否发本地通知，
    // Dart 不再重复发。其他平台 Dart 在后台时也发（仍走 NotificationService）。
    if (!Platform.isAndroid &&
        _lifecycle != AppLifecycleState.resumed) {
      NotificationService().showMessage(name: m.name, msg: m.msg);
    }

    final anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    final msgEntry = _MsgEntry(m, DateTime.now());
    setState(() {
      _messages.add((msgEntry, anim));
      _totalBytes += _entryBytes(msgEntry);
      // 满 1G 清理最早的内容
      while (_totalBytes > _maxBytes && _messages.isNotEmpty) {
        final (oldEntry, oldAnim) = _messages.removeAt(0);
        _totalBytes -= _entryBytes(oldEntry);
        oldAnim.dispose();
      }
    });
    SchedulerBinding.instance.addPostFrameCallback((_) {
      anim.forward();
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent + 120,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 网络切换事件：在消息列表插入居中系统提示气泡。
  /// 给用户视觉上的「刚才那个聊天现在不属于这个网络了」信号。
  void _onNetworkChanged(NetworkChangeEvent ev) {
    if (!mounted) return;
    final text = _formatNetworkNotice(ev.reason);
    if (text == null) return;

    final anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    final size = _entryBytes(_SysEntry(text, ev.timestamp));
    setState(() {
      _messages.add((_SysEntry(text, ev.timestamp), anim));
      _totalBytes += size;
      while (_totalBytes > _maxBytes && _messages.isNotEmpty) {
        final (oldEntry, oldAnim) = _messages.removeAt(0);
        _totalBytes -= _entryBytes(oldEntry);
        oldAnim.dispose();
      }
    });
    SchedulerBinding.instance.addPostFrameCallback((_) {
      anim.forward();
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 把 Kotlin 推过来的 reason（'available' / 'lost' / 'changed' / 'default-available'
  /// / 'default-lost'）或 Dart 端 connectivity_plus 的枚举字符串翻译成中文 UI 提示。
  /// 返回 null 表示不显示提示（比如语义模糊的 'changed'）。
  String? _formatNetworkNotice(String reason) {
    const base = '网络已切换';
    switch (reason) {
      case 'available':
        return '$base · 网络已就绪';
      case 'default-available':
        return '$base · 网络已就绪';
      case 'lost':
        return '$base · 网络已断开';
      case 'default-lost':
        return '$base · 网络已断开';
      case 'changed':
      case 'ConnectivityResult.wifi':
      case 'ConnectivityResult.mobile':
      case 'ConnectivityResult.ethernet':
      case 'ConnectivityResult.bluetooth':
      case 'ConnectivityResult.vpn':
      case 'ConnectivityResult.other':
      case 'ConnectivityResult.none':
        // 通用提示，不细分具体网络类型
        return '$base · 注意消息可能不再属于原网络';
      default:
        return '$base · $reason';
    }
  }

  Future<void> _onSend() async {
    final name = _nameCtrl.text.trim();
    final msg = _inputCtrl.text.trim();
    if (name.isEmpty) {
      _snack('先在顶部写一个你自己的昵称～', warning: true);
      FocusScope.of(context).requestFocus(_nameFocus);
      return;
    }
    if (msg.isEmpty) return;
    try {
      await _broadcaster.send(LanMessage(name: name, msg: msg));
      _inputCtrl.clear();
    } catch (e) {
      if (mounted) _snack('发送失败：$e', warning: true);
    }
    if (mounted) FocusScope.of(context).requestFocus(_inputFocus);
  }

  void _snack(String s, {bool warning = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(s),
        backgroundColor: warning ? Colors.deepOrangeAccent : null,
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        elevation: 0,
        scrolledUnderElevation: 1,
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(
                Icons.record_voice_over_rounded,
                color: Theme.of(context).colorScheme.primary,
                size: 28,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _NameField(controller: _nameCtrl),
              ),
            ],
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            height: 1,
            color: Theme.of(context).dividerColor.withValues(alpha:0.15),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? _EmptyHint(isDark: isDark)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
                      itemCount: _messages.length,
                      itemBuilder: (ctx, i) {
                        final (entry, anim) = _messages[i];
                        return switch (entry) {
                          _MsgEntry() => _MessageBubble(
                              entry: entry,
                              animation: anim,
                              isDark: isDark,
                              selfName: _nameCtrl.text.trim(),
                            ),
                          _SysEntry() => _SystemNotice(
                              entry: entry,
                              animation: anim,
                              isDark: isDark,
                            ),
                        };
                      },
                    ),
            ),
            _InputBar(
              controller: _inputCtrl,
              focusNode: _inputFocus,
              onSend: _onSend,
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================================================
// 消息列表条目类型：普通消息 / 系统提示
// ==========================================================================
sealed class _Entry {
  final DateTime receivedAt;
  const _Entry(this.receivedAt);
}

class _MsgEntry extends _Entry {
  final LanMessage message;
  const _MsgEntry(this.message, DateTime receivedAt)
      : super(receivedAt);
}

class _SysEntry extends _Entry {
  final String text;
  const _SysEntry(this.text, DateTime receivedAt) : super(receivedAt);
}

// ==========================================================================
// 顶部昵称输入
// ==========================================================================
class _NameField extends StatefulWidget {
  final TextEditingController controller;
  const _NameField({required this.controller});

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _focus = FocusNode();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 注意：按用户要求，name hash 上色只用于「收到的消息气泡」，输入框本身用主题色。
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      textInputAction: TextInputAction.done,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      decoration: InputDecoration(
        hintText: '点这里输入昵称…',
        hintStyle: TextStyle(
          fontSize: 15,
          color: scheme.onSurface.withValues(alpha: 0.45),
        ),
        prefixIcon: Icon(
          Icons.person_pin_rounded,
          color: scheme.primary.withValues(alpha: 0.8),
        ),
        filled: true,
        fillColor: scheme.primaryContainer.withValues(alpha: 0.35),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: scheme.primary,
            width: 1.6,
          ),
        ),
      ),
    );
  }
}

// ==========================================================================
// 空态提示
// ==========================================================================
class _EmptyHint extends StatelessWidget {
  final bool isDark;
  const _EmptyHint({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.82, end: 1.0),
            duration: const Duration(milliseconds: 1600),
            curve: Curves.easeInOutSine,
            builder: (_, v, child) {
              return Transform.scale(scale: v, child: child);
            },
            onEnd: () {},
            child: Icon(
              Icons.auto_awesome_rounded,
              size: 66,
              color: scheme.primary.withValues(alpha:0.55),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '还没有人喊话',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface.withValues(alpha:0.75),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '输入下方内容，发一条试试～',
            style: TextStyle(
              fontSize: 14,
              color: scheme.onSurface.withValues(alpha:0.45),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================================================
// 系统提示气泡（居中、灰色背景，区分于聊天消息）
// ==========================================================================
class _SystemNotice extends StatelessWidget {
  final _SysEntry entry;
  final Animation<double> animation;
  final bool isDark;

  const _SystemNotice({
    required this.entry,
    required this.animation,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = TimeOfDay.fromDateTime(entry.receivedAt);
    final timeStr = '${time.hour.toString().padLeft(2, '0')}'
        ':${time.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: AnimatedBuilder(
        animation: animation,
        builder: (_, child) {
          final t = Curves.easeOutCubic.transform(animation.value);
          return Opacity(
            opacity: 0.5 + 0.5 * t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 8),
              child: child,
            ),
          );
        },
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: (isDark ? Colors.white : Colors.black).withValues(alpha:0.06),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: scheme.onSurface.withValues(alpha:0.08),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.swap_horiz_rounded,
                  size: 14,
                  color: scheme.onSurface.withValues(alpha:0.5),
                ),
                const SizedBox(width: 6),
                Text(
                  entry.text,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha:0.55),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  timeStr,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha:0.35),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================================================
// 单条消息气泡
// ==========================================================================
class _MessageBubble extends StatelessWidget {
  final _MsgEntry entry;
  final Animation<double> animation;
  final bool isDark;
  final String selfName;

  const _MessageBubble({
    required this.entry,
    required this.animation,
    required this.isDark,
    required this.selfName,
  });

  @override
  Widget build(BuildContext context) {
    final palette = UserPalette.fromName(entry.message.name, isDark: isDark);
    final isSelf = selfName.isNotEmpty && selfName == entry.message.name;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: palette.bubbleBg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: isSelf ? const Radius.circular(16) : const Radius.circular(4),
          bottomRight: isSelf ? const Radius.circular(4) : const Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha:isDark ? 0.22 : 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.78,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  entry.message.name.isEmpty ? '(匿名)' : entry.message.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: palette.nameColor,
                  ),
                ),
              ),
              if (isSelf) ...[
                const SizedBox(width: 6),
                Icon(Icons.volume_up_rounded, size: 13, color: palette.nameColor),
              ],
            ],
          ),
          const SizedBox(height: 5),
          SelectionArea(
            child: Text(
              entry.message.msg,
              style: TextStyle(
                fontSize: 15.5,
                height: 1.42,
                color: palette.msgColor,
              ),
            ),
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: AnimatedBuilder(
        animation: animation,
        builder: (_, child) {
          final t = Curves.easeOutCubic.transform(animation.value);
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 18),
              child: Transform.scale(
                scale: 0.96 + 0.04 * t,
                alignment: isSelf ? Alignment.centerRight : Alignment.centerLeft,
                child: child,
              ),
            ),
          );
        },
        child: Row(
          mainAxisAlignment: isSelf ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isSelf) _Avatar(name: entry.message.name, palette: palette),
            const SizedBox(width: 8),
            Flexible(child: bubble),
            if (isSelf) ...[
              const SizedBox(width: 8),
              _Avatar(name: entry.message.name, palette: palette, isSelf: true),
            ],
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String name;
  final UserPalette palette;
  final bool isSelf;
  const _Avatar({required this.name, required this.palette, this.isSelf = false});

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.bubbleBg,
        shape: BoxShape.circle,
        border: Border.all(color: palette.nameColor.withValues(alpha:0.55), width: 1.4),
        boxShadow: [
          BoxShadow(
            color: palette.nameColor.withValues(alpha:isSelf ? 0.28 : 0.18),
            blurRadius: 6,
            spreadRadius: -1,
          ),
        ],
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: palette.nameColor,
        ),
      ),
    );
  }
}

// ==========================================================================
// 底部输入框 + 发送按钮
// ==========================================================================
class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha:0.05),
            blurRadius: 10,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 46, maxHeight: 160),
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.send,
                  style: TextStyle(fontSize: 15.5, color: scheme.onSurface),
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: '说点什么…',
                    hintStyle: TextStyle(
                      fontSize: 15,
                      color: scheme.onSurface.withValues(alpha:0.4),
                    ),
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _SendButton(onPressed: onSend, controller: controller),
          ],
        ),
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  final VoidCallback onPressed;
  final TextEditingController controller;
  const _SendButton({required this.onPressed, required this.controller});

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  void _onText() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final enabled = widget.controller.text.trim().isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: enabled ? widget.onPressed : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        width: 50,
        height: 50,
        transform: Matrix4.diagonal3Values(
          _pressed && enabled ? 0.92 : 1.0,
          _pressed && enabled ? 0.92 : 1.0,
          1.0,
        ),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: enabled
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [scheme.primary, scheme.primaryContainer.withBlue(220).withGreen(120)],
                )
              : null,
          color: enabled ? null : scheme.surfaceContainerHighest,
          boxShadow: [
            BoxShadow(
              color: (enabled ? scheme.primary : Colors.black).withValues(alpha:enabled ? 0.32 : 0.04),
              blurRadius: 12,
              offset: const Offset(0, 4),
              spreadRadius: -2,
            ),
          ],
        ),
        child: Icon(
          Icons.send_rounded,
          color: enabled ? Colors.white : scheme.onSurface.withValues(alpha:0.4),
          size: 22,
        ),
      ),
    );
  }
}
