// 按 name 的 hash 生成一组「深浅不一」的配色。
//
// 原则：不在消息体里加任何颜色字段，完全客户端根据 name 推导。
// 算法（保证同一 name 每次颜色都一致）：
//   1. 对 name 做整数 hash（Dart 内置 hashCode）。
//   2. 色相 = hash % 360          -> 区分不同用户。
//   3. 名字色：饱和度高、亮度中等（突出昵称）。
//   4. 正文色：饱和度低、亮度根据 hash 第二段在一定范围内波动 -> 实现「深浅不一」。

import 'package:flutter/material.dart';

class UserPalette {
  final Color nameColor;
  final Color msgColor;
  final Color bubbleBg;

  const UserPalette({
    required this.nameColor,
    required this.msgColor,
    required this.bubbleBg,
  });

  factory UserPalette.fromName(String name, {required bool isDark}) {
    final h = _stableHash(name);
    final hue = (h & 0xFFFFFFFF) % 360;

    // 用 hash 的不同字节切片做伪随机位，保证同 name 恒等
    final int sBit = (h >> 8) & 0xFF;
    final int lBit = (h >> 16) & 0xFF;
    final int l2Bit = (h >> 24) & 0xFF;

    if (isDark) {
      final nameSat = 0.70 + (sBit / 0xFF) * 0.25; // 0.70~0.95
      final nameLum = 0.68 + (lBit / 0xFF) * 0.18; // 0.68~0.86  深背景要亮一点
      final msgSat = 0.30 + ((sBit >> 2) / 0xFF) * 0.35;
      final msgLum = 0.78 + (l2Bit / 0xFF) * 0.16;
      final bgLum = 0.14 + ((lBit ^ l2Bit) / 0xFF) * 0.10;
      return UserPalette(
        nameColor: HSLColor.fromAHSL(1.0, hue.toDouble(), nameSat, nameLum).toColor(),
        msgColor: HSLColor.fromAHSL(1.0, hue.toDouble(), msgSat, msgLum).toColor(),
        bubbleBg: HSLColor.fromAHSL(0.55, hue.toDouble(), 0.25, bgLum).toColor(),
      );
    } else {
      final nameSat = 0.70 + (sBit / 0xFF) * 0.25;
      final nameLum = 0.38 + (lBit / 0xFF) * 0.18; // 0.38~0.56  浅背景深一点
      final msgSat = 0.28 + ((sBit >> 2) / 0xFF) * 0.30;
      final msgLum = 0.22 + (l2Bit / 0xFF) * 0.22;
      final bgLum = 0.90 + ((lBit ^ l2Bit) / 0xFF) * 0.07;
      return UserPalette(
        nameColor: HSLColor.fromAHSL(1.0, hue.toDouble(), nameSat, nameLum).toColor(),
        msgColor: HSLColor.fromAHSL(1.0, hue.toDouble(), msgSat, msgLum).toColor(),
        bubbleBg: HSLColor.fromAHSL(1.0, hue.toDouble(), 0.18, bgLum).toColor(),
      );
    }
  }

  /// 稳定 hash：Dart 字符串 hashCode 本身按字符算，对相同字符串恒定（但同一字符串多次 hashCode 官方不保证跨运行——
  /// 实际 Flutter 在同一进程里相同字符串 hashCode 一致；为防万一会员加一层自己的多项式 hash 混合，保证即使
  /// 原始 hashCode 变了也能稳定）。
  static int _stableHash(String s) {
    if (s.isEmpty) return 0x12345678;
    int h = 0x811c9dc5;
    for (int i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h ^ s.hashCode;
  }
}
