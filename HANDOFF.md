# 工作恢复文档（Handoff）

> 供下一次会话快速恢复上下文。最后更新：2026-09-06（清理便携 SDK，源码推 GitHub，Actions 自动 Release）
>
> **2026-09-06 清理**：已从本目录删除便携 `flutter/`、`android_sdk/`、`jdk/`、`git/`、`build/` 以及网吧编译日志 / VS 安装器。本地开发改用系统 Flutter。安装包走 GitHub Releases（打 `v*` 标签即可）。原先编译好的 APK / Windows 包仍在 `0A产物！！！！！/`，不进 git。

---

> 上一版上下文：2026-08-17（第四轮 - 后台 Service + 网络切换提示，编译验证通过）

## 一句话现状

「局域网喊话」MVP 完成 + **双平台编译成功 + 真机测试通过**。两个安装包已复制到项目根目录：
- `lan_broadcast.apk`（Android，46.9 MB）
- `lan_broadcast_windows\`（Windows，含 exe + dll + data）

功能：UDP 组播收发 + 回显断网检测 + connectivity_plus 事件流 + name hash 上色 + 昵称持久化 + 1G 内存清理 + Android 后台通知 + Android MulticastLock。`dart analyze lib\` 0 issue。

**测试结果**（2026-08-10）：本机回显正常（组播回环工作），跨设备未通（电脑和手机在不同网段，符合预期——组播默认不跨网段）。

---

## 环境信息

> **盘符活**：网吧机器盘符可能为 D/F/E 等，本文档所有路径均为**相对项目根**（`.\xxx` = 项目根下的 xxx）。
> 启动命令里请用 `$PWD` 让 PowerShell 自己展开为当前盘符绝对路径，不要把盘符写死。

| 项 | 值 |
|---|---|
| 项目根 | 即本仓库所在目录（盘符随时变，假设 `$PWD`） |
| 英文 junction | `<任意盘>:\workspace\ProjectFlyUp\lan_broadcast` → 项目根（**Windows 编译必须用此英文路径**，中文 `局域网喊话app` 致 MSBuild 乱码） |
| Flutter SDK | `.\flutter\` （3.44.8 stable，Dart 3.12.2） |
| MinGit | `.\git\` （2.55.0.3，从华为云镜像下载，给 flutter pub get 用） |
| VS Build Tools | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools`（17.14.37，含 VCTools + Windows SDK + CMake + Ninja，唯一装到系统目录的例外） |
| JDK | `.\jdk\`（OpenJDK 17.0.2，华为云镜像下载，activate.ps1 自动设 JAVA_HOME） |
| Android SDK | `.\android_sdk\`（SDK 36 + BuildTools 28.0.3 + platform-tools 37.0.1，activate.ps1 自动设 ANDROID_HOME） |
| pub 镜像 | `https://pub.dev`（官方，国内 flutter-io.cn / flutter.cn 镜像 TLS/socket 不稳） |
| engine 镜像 | `https://storage.flutter-io.cn` |
| 缓存重定向 | `.\flutter\.pub-cache`、`.\flutter\.appdata\Roaming`、`.\flutter\.appdata\Local` |
| 激活脚本 | `.\activate.ps1` |
| 目标平台 | Windows 桌面 + Android |
| 组播约定 | `239.255.255.155 : 1556`（尾号 155 + 端口 1556） |

### 启动开发环境（每个新终端必须执行）

```powershell
# 切到本仓库（盘符自己看，下面命令在哪个盘执行就生效）
cd <项目根>
. .\activate.ps1
# 验证
flutter --version
git --version
```

> 注意：必须用 `. `（dot-source）执行，否则环境变量不生效。
> activate.ps1 自动检测项目根（`$MyInvocation.MyCommand.Path`），所以 cd 到哪都能用。
> activate.ps1 会自动把 `git\cmd` 加到 PATH（如果存在）。

### 静态分析（不依赖 activate.ps1 也能跑）

```powershell
cd <项目根>
$env:PUB_CACHE    = "$PWD\flutter\.pub-cache"
$env:APPDATA     = "$PWD\flutter\.appdata\Roaming"
$env:LOCALAPPDATA= "$PWD\flutter\.appdata\Local"
& "$PWD\flutter\bin\cache\dart-sdk\bin\dart.exe" analyze lib\
```

---

## 设计总览

### 核心约束（来自用户第一轮 9 条）

1. UDP 组播，组播 IP 尾号 155，端口 1556
2. 后端极简：发送 / 接收后推给页面，不做更多
3. 单页极简 IM：展示页面 + 文字输入框 + 发送按钮
4. 流程：发送 → 组播网络 → 本机和同组播设备收到 → 推到消息记录
5. 消息体严格两字段：`name` + `msg`，JSON + UTF-8
6. 配色来自 name hash，客户端功能，不在消息体实现
7. 名字色和正文色深浅不一
8. 特效和动画随意
9. 昵称在页面顶部设置，不做重名校验

### 第二轮新增（7 条）

1. **颜色澄清**：name hash 上色只用于收到的消息气泡/头像，**不**用于昵称输入框（输入框用主题色）
2. **MinGit**：下载 portable git 到项目 `git/`（华为云镜像），pub get 用官方 pub.dev
3. **昵称持久化**：shared_preferences，防抖 500ms 保存
4. **消息列表 1G 清理**：累计字节数超 1 GiB 时从头部移除最早的消息
5. **网络变化重新 join**（第三轮修订）：两套互补机制——① connectivity_plus 事件流（系统级网络变化立即触发）② 回显检测（发消息后 2 秒没收到组播回环 = 断网 → 重新 join）。**不本地插入消息**，UI 显示完全依赖 multicastLoopback 回环。平时组播地址零流量
6. **后台通知**：app 在后台时收消息发系统通知（Android 用 flutter_local_notifications，Windows 暂不支持留 TODO）
7. **Android 权限**：INTERNET / ACCESS_NETWORK_STATE / ACCESS_WIFI_STATE / CHANGE_WIFI_MULTICAST_STATE / POST_NOTIFICATIONS / VIBRATE + MulticastLock（MethodChannel → Kotlin）

---

## 已完成

### 环境
- [x] Flutter SDK 3.44.8 + activate.ps1（缓存重定向 + 镜像 + PATH）
- [x] MinGit 2.55.0.3 下载到 `git/`（华为云镜像，38MB）
- [x] activate.ps1 自动检测 `git\cmd` 并加 PATH
- [x] pub 镜像从 `pub.flutter-io.cn`（TLS 错误）→ `pub.flutter.cn`（socket 错误）→ `pub.dev`（官方，可用）
- [x] `.gitignore` 忽略 `/flutter/` 和 `/git/`
- [x] `flutter pub get` 成功（52 个依赖，含 shared_preferences + flutter_local_notifications）

### 代码
- [x] [lib/models/lan_message.dart](lib/models/lan_message.dart) — 仅 `name` + `msg` 两字段
- [x] [lib/services/lan_broadcaster.dart](lib/services/lan_broadcaster.dart) — UDP 组播收发核心（抽象层）
  - 常量：`multicastIp = '239.255.255.155'`、`port = 1556`
  - 抽象类 `LanBroadcaster`，平台分流：
    - **Android**：`_AndroidLanBroadcaster` 走 MethodChannel/EventChannel 与 Kotlin Foreground Service 通信（后台 Dart isolate 暂停也能收）
    - **桌面/iOS/macOS/Linux**：`_DartLanBroadcaster` 用 Dart `RawDatagramSocket`
  - 绑定 `0.0.0.0:1556`，遍历本机所有 IPv4 接口 `joinMulticast`（多网卡兜底，桌面端实现）
  - `multicastLoopback = true`；**不本地插入**，UI 显示完全依赖组播回环
  - **断网检测机制 1**：Android=Kotlin `ConnectivityManager.NetworkCallback` / 桌面=`connectivity_plus` `onConnectivityChanged`；网络变化时立即重新 join，并推 `NetworkChangeEvent` 给 UI 居中提示
  - **断网检测机制 2**：回显检测（send 后记录 hash，2 秒内没收到匹配回环 → 重新 join，桌面端实现）
  - 暴露 `Stream<NetworkChangeEvent> get onNetworkChanged` 供 UI 监听
- [x] [lib/utils/user_palette.dart](lib/utils/user_palette.dart) — name → 三色系配色
  - FNV-1a 稳定 hash → 色相 % 360；hash 字节切片独立抖 name/msg 的饱和度和亮度
  - **只用于消息气泡和头像**，不用于输入框
- [x] [lib/services/notification_service.dart](lib/services/notification_service.dart) — 后台通知
  - flutter_local_notifications 18.0.1
  - Android/iOS/macOS/Linux 支持；Windows 不支持（跳过）
  - Android 13+ 运行时请求 POST_NOTIFICATIONS 权限
  - **Android 端 Kotlin Service 自己发通知**，Dart 这层只在非 Android 平台触发
- [x] [lib/main.dart](lib/main.dart) — 单页 UI + 集成
  - 顶部昵称栏：**主题色**（无 palette），持久化到 shared_preferences（防抖 500ms）
  - 消息列表：name hash 上色，自己/别人区分，淡入+上移+缩放动画
  - **1G 内存清理**：累计字节数超 1 GiB 时从头部移除最早消息（含系统提示条目）
  - **后台通知**：Android 由 Kotlin Service 处理；其他平台 AppLifecycleState != resumed 时 Dart 发通知
  - **前后台状态**：`didChangeAppLifecycleState` 调 `_broadcaster.setForeground(bool)`，Android 通知 Service 调整通知行为
  - **网络切换系统提示**：监听 `onNetworkChanged`，在消息列表插入居中样式 `_SysEntry` 气泡（避免用户切网后还以为在原网络聊天）
  - 消息列表条目类型：`sealed class _Entry` → `_MsgEntry` / `_SysEntry`
  - 底部输入栏 + 渐变发送按钮
  - 亮暗双主题 + SelectionArea

### Android 平台（Kotlin Foreground Service）
- [x] [android/app/src/main/AndroidManifest.xml](android/app/src/main/AndroidManifest.xml) — 权限：INTERNET / ACCESS_NETWORK_STATE / ACCESS_WIFI_STATE / CHANGE_WIFI_MULTICAST_STATE / POST_NOTIFICATIONS / VIBRATE / WAKE_LOCK / FOREGROUND_SERVICE / FOREGROUND_SERVICE_DATA_SYNC；声明 `LanBroadcastService` `foregroundServiceType="dataSync"`
- [x] [android/app/src/main/kotlin/com/example/lan_broadcast/LanBroadcastService.kt](android/app/src/main/kotlin/com/example/lan_broadcast/LanBroadcastService.kt) — 前台服务，持有 UDP MulticastSocket + WifiManager.MulticastLock + PowerManager.WakeLock + ConnectivityManager.NetworkCallback，后台持续收消息；收到消息时若 app 不在前台则发本地通知；网络变化时通过 EventChannel 推 `network` 事件给 Dart
- [x] [android/app/src/main/kotlin/com/example/lan_broadcast/MainActivity.kt](android/app/src/main/kotlin/com/example/lan_broadcast/MainActivity.kt) — MethodChannel `lan_broadcast/control` + EventChannel `lan_broadcast/events`；转发 start/stop/send/setForeground 到 Service

### 验证
- [x] `dart analyze lib\` → `No issues found!`（0 errors / 0 warnings / 0 infos）

---

## 待办

- [x] **flutter build windows** ✅ 编译成功（2026-08-10），产物复制到 `lan_broadcast_windows\`
- [x] **flutter build apk** ✅ 编译成功（2026-08-17 重新验证，46.8MB），产物复制到 `lan_broadcast.apk`
- [x] **真机测试** ✅ 通过（2026-08-10）：本机回显正常，跨设备因网段不同未通（符合预期）
- [ ] **Windows 后台通知**：flutter_local_notifications 不支持 Windows。如需 Windows 通知可加 `local_notifier` 包（TODO，用户说「如 Windows 可实现也可以加」）
- [ ] 用户后续设计输入

### 编译方法（Android APK）

> **关键**：ANDROID_HOME 必须用英文 junction 路径，否则 NDK 解压时中文路径乱码失败。
> Gradle 已配置腾讯云镜像（gradle wrapper）+ 阿里云镜像（maven 仓库），否则国内连不上 services.gradle.org。

```powershell
# 切到项目根（任意盘符都行，只要这个目录就是仓库根）
cd <项目根>
. .\activate.ps1
$env:PUB_HOSTED_URL = 'https://pub.dev'
# ANDROID_HOME / JAVA_HOME 必须用英文 junction 路径，否则 NDK 解压时中文路径乱码失败
# 注意 junction 的盘符也跟着项目根走，下面用脚本自动获取
$junctionParent = Split-Path -Parent $PWD       # 取上级（含 ProjectFlyUp）
$junctionPath   = Join-Path $junctionParent 'lan_broadcast'
if (-not (Test-Path $junctionPath)) {
    New-Item -ItemType Junction -Path $junctionPath -Target $PWD | Out-Null
}
cd $junctionPath
. .\activate.ps1   # 在英文路径下再激活一次，确保 env 是英文路径
$env:ANDROID_HOME = "$PWD\android_sdk"
$env:JAVA_HOME    = "$PWD\jdk"
flutter build apk --release
# → build\app\outputs\flutter-apk\app-release.apk
```

**注意**：`android/app/build.gradle.kts` 已加 `isCoreLibraryDesugaringEnabled = true` + `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")`，因为 flutter_local_notifications 需要 core library desugaring。

### 编译方法（Windows）

> **关键**：项目路径含中文（`局域网喊话app`），MSBuild/CMake 会把 UTF-8 中文路径用 GBK 解码 → "锟斤拷"乱码 → `Unable to read file` 错误。
> **解决**：用英文 junction 路径编译。

```powershell
# 1. 先到项目根，确保英文 junction 存在（同盘符下，上级目录加 lan_broadcast 名字）
cd <项目根>
$junctionParent = Split-Path -Parent $PWD
$junctionPath   = Join-Path $junctionParent 'lan_broadcast'
if (-not (Test-Path $junctionPath)) {
    New-Item -ItemType Junction -Path $junctionPath -Target $PWD | Out-Null
}

# 2. 在英文路径下编译
cd $junctionPath
. .\activate.ps1
$env:PUB_HOSTED_URL = 'https://pub.dev'  # flutter.cn 镜像不通不了，用官方
flutter build windows

# 产物：build\windows\x64\runner\Release\lan_broadcast.exe
```

---

## 关键文件速查

| 文件 | 作用 |
|---|---|
| [activate.ps1](activate.ps1) | 环境激活：PATH(git+flutter) + 镜像 + 缓存重定向 + 自动维护 `android/local.properties`（写英文 junction 路径，规避中文路径乱码） |
| [lib/main.dart](lib/main.dart) | 单页 UI + 生命周期 + 持久化 + 1G清理 + 通知 + 网络切换系统提示气泡 |
| [lib/services/lan_broadcaster.dart](lib/services/lan_broadcaster.dart) | UDP 组播收发抽象层（Android → Kotlin Service；桌面 → Dart socket）+ 网络变化事件流 |
| [lib/services/notification_service.dart](lib/services/notification_service.dart) | 后台消息通知（非 Android 平台） |
| [lib/models/lan_message.dart](lib/models/lan_message.dart) | 消息模型：name + msg |
| [lib/utils/user_palette.dart](lib/utils/user_palette.dart) | name hash → 配色 |
| [android/app/src/main/AndroidManifest.xml](android/app/src/main/AndroidManifest.xml) | 9 个权限 + 声明 LanBroadcastService |
| [android/app/src/main/kotlin/.../LanBroadcastService.kt](android/app/src/main/kotlin/com/example/lan_broadcast/LanBroadcastService.kt) | Foreground Service：UDP socket + MulticastLock + WakeLock + NetworkCallback + 后台消息通知 |
| [android/app/src/main/kotlin/.../MainActivity.kt](android/app/src/main/kotlin/com/example/lan_broadcast/MainActivity.kt) | MethodChannel/EventChannel 转发到 Service |
| [pubspec.yaml](pubspec.yaml) | shared_preferences + flutter_local_notifications + connectivity_plus |

---

## 网吧环境踩坑记录（持续更新）

1. **C 盘权限锁定** → activate.ps1 重定向 PUB_CACHE/APPDATA/LOCALAPPDATA
2. **没装 git.exe** → 下载 MinGit 2.55.0.3 到 `git/`，activate.ps1 自动加 PATH
3. **pub 镜像不稳**：`pub.flutter-io.cn` TLS 错误、`pub.flutter.cn` socket 错误 → 改用官方 `pub.dev`（可用）
4. **盘符变化** D→F：`.dart_tool/package_config.json` 里 `file:///d:/...` 全量替换成 `file:///f:/...`（每个新盘符首次 `flutter pub get` 会自动重写）
5. **flutter clean 后 windows/flutter/ephemeral 被删** → 手动重建目录后再 pub get（symlink 错误不致命，build 会继续）
6. **PS 5.1 中文乱码** → activate.ps1 全 ASCII
7. **不修改系统**：所有变量只在当前 shell（VS Build Tools 是唯一例外，装到了系统目录）
8. **缺 MSVC** → 下载 vs_BuildTools.exe（4.5MB 安装器），静默安装 VCTools 工作负载（~2-3GB，含 MSVC + Windows SDK + CMake + Ninja）
9. **中文路径致 MSBuild 乱码**：`局域网喊话` → `锟斤拷`（UTF-8 被 GBK 解码）→ `Unable to read file` → **用英文 junction `<项目父目录>\lan_broadcast` 编译**（`activate.ps1` 会自动建 junction + 把 `local.properties` 里的 `flutter.sdk`/`sdk.dir` 改写成 junction 路径，盘符跟着项目根走）
10. **Android SDK 需要 cmdline-tools/latest 布局** → 下载的 commandlinetools zip 解压后是 `cmdline-tools/bin/`，Flutter 期望 `cmdline-tools/latest/bin/` → 手动把 bin/lib 移入 `latest/`
11. **Flutter 需要 Android SDK 36 + BuildTools 28.0.3**（不是最新的 34），sdkmanager 安装对应版本
12. **Gradle 下载失败**（services.gradle.org 超时）→ `gradle-wrapper.properties` 改腾讯云镜像 `mirrors.cloud.tencent.com/gradle/`；`settings.gradle.kts` + `build.gradle.kts` 加阿里云 maven 镜像
13. **NDK 28.2.13676358 缺失** → sdkmanager 安装；**ANDROID_HOME 必须用英文 junction 路径**，否则 NDK 解压时中文路径乱码失败
14. **flutter_local_notifications 需要 core library desugaring** → `app/build.gradle.kts` 加 `isCoreLibraryDesugaringEnabled = true` + `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")`
15. **`local.properties` 用 ASCII 编码写中文路径会变成 `?????`**：Gradle 把 `local.properties` 当 ISO-8859-1 读，中文无法直接写。`activate.ps1` 已修：写 `flutter.sdk`/`sdk.dir` 时**优先用英文 junction 路径**，没有 junction 才回退到原项目路径（此时编译可能失败）。所以**每次新 shell 先 dot-source `activate.ps1` 再编译**，由它保证 junction 存在 + `local.properties` 是 ASCII 安全的
16. **PowerShell 5.1 把 native command 的 stderr 当 error 流**：`flutter build` 启动时往 stderr 写「Make sure you trust this source」会被 PS 包装成 `NativeCommandError` 终止命令。绕过：在调用前 `$ErrorActionPreference = 'Continue'` + `$global:PSNativeCommandUseErrorActionPreference = $false`，并用 `& flutter ... 2>&1 | Tee-Object log` 合并流
17. **Kotlin `Unresolved reference 'Builder'`**：注册 `ConnectivityManager.registerNetworkCallback` 时第一个参数要的是 `NetworkRequest`，不是 `NetworkCapabilities`。错写 `NetworkCapabilities.Builder().addTransportType(...)` 会编译失败。正确：`import android.net.NetworkRequest` + `NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()`

---

## 硬性约束（来自用户）

- 文件夹层数少 → SDK 在 `flutter/`，MinGit 在 `git/`，都不嵌套
- 只动项目文件夹，其他不动
- 不做系统修改（网吧还原）
- **不擅自补全用户没提到的功能**：能做的部分做掉，缺失的部分明确提醒
