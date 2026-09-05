package com.example.lan_broadcast

import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val controlChannel = "lan_broadcast/control"
    private val eventsChannel = "lan_broadcast/events"

    private var serviceStarted = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // EventChannel: Service -> Dart 推消息事件 / 网络变化事件 / ready 事件
        EventChannel(messenger, eventsChannel).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    LanBroadcastService.eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    LanBroadcastService.eventSink = null
                }
            },
        )

        // MethodChannel: Dart -> Service 启动/停止/发送/前后台状态
        MethodChannel(messenger, controlChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startLanService()
                    result.success(true)
                }
                "stop" -> {
                    stopLanService()
                    result.success(true)
                }
                "send" -> {
                    val name = call.argument<String>("name") ?: ""
                    val msg = call.argument<String>("msg") ?: ""
                    val ok = LanBroadcastService.sendMessage(name, msg)
                    result.success(ok)
                }
                "setForeground" -> {
                    val fg = call.argument<Boolean>("foreground") ?: true
                    LanBroadcastService.isAppInForeground = fg
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startLanService() {
        if (serviceStarted) return
        serviceStarted = true
        try {
            val intent = Intent(this, LanBroadcastService::class.java)
            // Android 8+ 必须 startForegroundService（在 Activity resumed 时调用合法）
            ContextCompat.startForegroundService(this, intent)
            Log.i("MainActivity", "LanBroadcastService start requested")
        } catch (e: Exception) {
            Log.e("MainActivity", "startLanService failed", e)
            serviceStarted = false
        }
    }

    private fun stopLanService() {
        if (!serviceStarted) return
        serviceStarted = false
        try {
            stopService(Intent(this, LanBroadcastService::class.java))
        } catch (e: Exception) {
            Log.w("MainActivity", "stopLanService failed", e)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onDestroy() {
        // 不在 Activity 销毁时停止 Service：让 Service 在后台继续运行
        // 真正停止由 Dart 的 dispose() 主动调用（一般也不会调，app 整个退出时系统会清理）
        super.onDestroy()
    }
}
