# 局域网喊话

同 Wi-Fi / 局域网里的轻量喊话工具。消息走 UDP 组播，不经过服务器，打开就能说。

支持 **Android** 和 **Windows**。

## 做什么用

在教室、机房、宿舍同一网段里，互相发一句短消息。没有账号，没有云，断网也没关系——只要还在同一个局域网。

- 组播地址：`239.255.255.155:1556`
- 消息体只有两个字段：`name` + `msg`（JSON / UTF-8）
- 昵称按名字哈希上色，自己的气泡和别人的不一样
- 昵称会记在本地
- Android 后台用前台服务继续收消息，并弹出通知
- 切网 / 断线时会在聊天里插一条系统提示，并重新加入组播

组播默认**不跨网段、不跨 VLAN**。电脑连校园网、手机连热点，互相看不见是正常的。

## 下载安装包

每次打上 `v*` 标签并推送到 GitHub，Actions 会自动：

1. 编译 Android APK 和 Windows 绿色包
2. 用提交记录生成 Release 说明
3. 把安装包挂到 [Releases](https://github.com/SudaZitong/lan-broadcast/releases)

也可以在仓库的 **Actions** 页手动跑 `Release` 工作流，只出构建产物、不打正式版。

## 本地开发

需要本机已安装 [Flutter](https://docs.flutter.dev/get-started/install)（stable，Dart ≥ 3.12）。

```bash
flutter pub get
flutter run
```

只编安装包：

```bash
flutter build apk --release
flutter build windows --release
```

Windows 编译路径里不要有中文。如果项目在 `局域网喊话app` 这种目录下，先建一个英文 junction 再编：

```powershell
$root = (Get-Item -LiteralPath .).FullName
$parent = Split-Path $root
$junction = Join-Path $parent "lan_broadcast"
if (-not (Test-Path $junction)) {
    New-Item -ItemType Junction -Path $junction -Target $root | Out-Null
}
Set-Location $junction
flutter build windows --release
```

## 自己发一版

改完代码、版本号写在 `pubspec.yaml` 的 `version:`（例如 `1.0.1+2`），然后：

```bash
git tag v1.0.1
git push origin v1.0.1
```

GitHub 会自己建 Release。说明文字来自这次 tag 相对上一版之间的提交。

## 项目结构

```
lib/
  main.dart                      单页聊天 UI
  models/lan_message.dart        消息：name + msg
  services/lan_broadcaster.dart  UDP 组播（Android 走 Kotlin 服务，桌面走 Dart socket）
  services/notification_service.dart
  utils/user_palette.dart        昵称哈希配色
android/app/src/main/kotlin/.../LanBroadcastService.kt
```

更完整的设计说明和网吧环境踩坑见 [HANDOFF.md](HANDOFF.md)。

## 许可

MIT。个人小工具，随便用。
