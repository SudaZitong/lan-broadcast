# 局域网喊话

基于 UDP 组播的局域网即时通讯。无需服务器、无需账号，同一网段内的 Android 与 Windows 设备可直接收发文本。

## 功能

- 文本消息，协议仅含 `name`、`msg` 两个字段
- 按昵称哈希为气泡着色
- 昵称本地持久化
- Android 以后台前台服务持续接收，并发送系统通知
- 网络切换或断线后自动重新加入组播，并在会话中提示

组播不能跨网段、不能跨 VLAN，设备必须接在同一二层网络。

## 协议

| 项 | 值 |
| --- | --- |
| 组播地址 | `239.255.255.155` |
| 端口 | `1556` |
| 编码 | UTF-8 JSON：`{"name":"...","msg":"..."}` |

## 安装

从 [Releases](https://github.com/SudaZitong/lan-broadcast/releases) 下载：

- Android：`lan_broadcast-vX.Y.Z-android.apk`
- Windows：`lan_broadcast-vX.Y.Z-windows-x64.zip`，解压后运行 `lan_broadcast.exe`

当前构建使用 debug 签名，仅供自用，不适合上架应用商店。

## 从源码构建

需要 [Flutter](https://docs.flutter.dev/get-started/install) stable（Dart ≥ 3.12）。Windows 还需 Visual Studio 的「使用 C++ 的桌面开发」工作负载。

```bash
flutter pub get
flutter run
```

发行包：

```bash
flutter build apk --release
flutter build windows --release
```

Windows 工程路径请使用英文。路径含中文时，MSBuild 可能无法正确读取工程文件。

## 发布

推送 `v*` 标签后，GitHub Actions 会编译 Android APK 与 Windows 压缩包，根据提交记录生成说明，并创建 [GitHub Release](https://github.com/SudaZitong/lan-broadcast/releases)。

```bash
git tag v1.0.1
git push origin v1.0.1
```

也可在仓库 Actions 中手动运行 `Release` 工作流，只构建、不发布。

## License

[MIT](LICENSE)
