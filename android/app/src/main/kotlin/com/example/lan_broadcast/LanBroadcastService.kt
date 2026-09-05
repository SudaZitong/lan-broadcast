package com.example.lan_broadcast

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.nio.charset.StandardCharsets

/**
 * 局域网喊话前台服务。
 *
 * 解决 Android 后台 Dart isolate 暂停导致 UDP 组播接收失效的问题：
 * 把 UDP socket 收发逻辑完全移到 Kotlin Service。Service 持有
 *   - WifiManager.MulticastLock：防止 Wi-Fi 省电模式丢弃组播包
 *   - PowerManager.PARTIAL_WAKE_LOCK：防止 CPU 进入睡眠
 *   - UDP MulticastSocket：绑定 0.0.0.0:1556，join 239.255.255.155
 *
 * 收到消息时：
 *   - 前台：通过 EventChannel 推给 Dart（UI 显示，Dart 不再持有 socket）
 *   - 后台：发本地通知到 channel "lan_broadcast_msg"
 *
 * 网络切换（Wi-Fi/移动数据/断开）：
 *   - ConnectivityManager.NetworkCallback 监听
 *   - 立即重新 join 组播
 *   - 通过 EventChannel 推 {"type":"network", ...} 给 Dart（UI 居中系统提示）
 *
 * 启动方式：MainActivity 收到 Dart 的 "start" MethodChannel 调用后调
 *   ContextCompat.startForegroundService(this, LanBroadcastService::class.java)
 *   （Android 8+ 不允许后台启动前台服务，必须在 Activity resumed 时启动）
 *
 * 生命周期：START_STICKY，进程被系统杀掉后系统会重启 Service（但 socket/锁要重新获取）。
 */
class LanBroadcastService : Service() {

    companion object {
        private const val TAG = "LanBroadcastService"

        const val MULTICAST_IP = "239.255.255.155"
        const val PORT = 1556

        const val FG_CHANNEL_ID = "lan_broadcast_fg"
        const val MSG_CHANNEL_ID = "lan_broadcast_msg"
        const val FG_NOTIFICATION_ID = 1

        /** 由 MainActivity 设置：EventChannel sink，用于推事件给 Dart。 */
        @Volatile
        var eventSink: EventChannel.EventSink? = null

        /** 由 Dart 通过 MethodChannel 报告：当前 Flutter app 是否在前台。 */
        @Volatile
        var isAppInForeground: Boolean = true

        /** 当前 Service 单例（启动后非空，销毁后置空）。 */
        @Volatile
        private var instance: LanBroadcastService? = null

        /** Dart 调用 send 时的入口。返回 true 表示发送成功。 */
        fun sendMessage(name: String, msg: String): Boolean {
            val s = instance ?: return false
            return s.trySend(name, msg)
        }

        private val mainHandler = Handler(Looper.getMainLooper())

        /** 向 EventChannel 推事件（线程安全，自动切回主线程）。 */
        fun postEvent(event: Map<String, Any?>) {
            val sink = eventSink ?: return
            mainHandler.post {
                try {
                    sink.success(event)
                } catch (e: Exception) {
                    Log.w(TAG, "eventSink.success failed", e)
                }
            }
        }
    }

    private var socket: MulticastSocket? = null
    private var receiveThread: Thread? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var defaultNetworkCallback: ConnectivityManager.NetworkCallback? = null

    @Volatile
    private var running = false

    /** 待 socket ready 时缓存的待发送数据，避免 Dart 在 socket 初始化窗口期发消息丢失。 */
    private val pendingQueue = mutableListOf<Pair<String, String>>()

    // 网络事件首次抑制 + 去重：
    //   - 系统一注册 NetworkCallback 就会立即回调当前网络状态，但此时并不是用户切换网络，
    //     不应该往 UI 推 "网络已切换" 提示，否则用户一打开 app 就看到假提示。
    //   - Dart 端 _DartLanBroadcaster 有 _connectivityFirstEvent 跳过首次，Kotlin 这里对齐。
    @Volatile
    private var firstNetworkEventSuppressed = false

    @Volatile
    private var lastNetworkEventTs = 0L
    @Volatile
    private var lastNetworkEventReason: String? = null
    private val networkEventDedupMs = 800L

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android 14+ 必须明确 foregroundServiceType=dataSync
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                FG_NOTIFICATION_ID,
                buildNotification("局域网喊话运行中"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(FG_NOTIFICATION_ID, buildNotification("局域网喊话运行中"))
        }

        acquireLocks()
        registerNetworkCallback()

        // 启动 socket（异步，避免 ANR）
        Thread {
            try {
                initSocketLocked()
                startReceivingLocked()
            } catch (e: Exception) {
                Log.e(TAG, "initSocket/receive failed", e)
            }
        }.start()

        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        receiveThread?.interrupt()
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        releaseLocks()
        unregisterNetworkCallback()
        instance = null
        super.onDestroy()
    }

    /** Service 不支持 bind（只通过静态方法 + EventChannel 通信）。 */
    override fun onBind(intent: Intent?): IBinder? = null

    // --------------------------- 通知 channel ---------------------------

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        val fg = NotificationChannel(
            FG_CHANNEL_ID,
            "前台服务",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持局域网喊话在后台运行"
            setShowBadge(false)
        }
        nm.createNotificationChannel(fg)

        // 即使 Dart 端 flutter_local_notifications 也会创建此 channel，
        // 这里再创建一次是幂等的，避免 Kotlin 后台发消息时 channel 不存在。
        val msg = NotificationChannel(
            MSG_CHANNEL_ID,
            "局域网喊话消息",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "后台收到的局域网喊话消息通知"
            enableVibration(true)
        }
        nm.createNotificationChannel(msg)
    }

    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, FG_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("局域网喊话")
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    // --------------------------- 锁 ---------------------------

    private fun acquireLocks() {
        try {
            val wifi = getSystemService(WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("lan_broadcast").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "acquire MulticastLock failed", e)
        }
        try {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "lan_broadcast:cpu",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "acquire WakeLock failed", e)
        }
    }

    private fun releaseLocks() {
        try { multicastLock?.release() } catch (_: Exception) {}
        multicastLock = null
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {}
        wakeLock = null
    }

    // --------------------------- 网络变化监听 ---------------------------

    private fun registerNetworkCallback() {
        firstNetworkEventSuppressed = false
        val cm = getSystemService(CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                handleNetworkChanged("available")
            }

            override fun onLost(network: Network) {
                handleNetworkChanged("lost")
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                // 切换 Wi-Fi ↔ 移动数据等会触发；但 capabilities 一注册就会立即回调一次，
                // 首次事件会被 firstNetworkEventSuppressed 抑制，不会推 UI。
                handleNetworkChanged("changed")
            }
        }
        val defaultCb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                handleNetworkChanged("available")
            }

            override fun onLost(network: Network) {
                handleNetworkChanged("lost")
            }
        }
        try {
            cm.registerNetworkCallback(
                NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .build(),
                cb,
            )
            cm.registerDefaultNetworkCallback(defaultCb)
        } catch (e: Exception) {
            Log.w(TAG, "registerNetworkCallback failed", e)
        }
        networkCallback = cb
        defaultNetworkCallback = defaultCb
    }

    private fun unregisterNetworkCallback() {
        val cm = getSystemService(CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        try { networkCallback?.let { cm.unregisterNetworkCallback(it) } } catch (_: Exception) {}
        try { defaultNetworkCallback?.let { cm.unregisterNetworkCallback(it) } } catch (_: Exception) {}
        networkCallback = null
        defaultNetworkCallback = null
    }

    private fun handleNetworkChanged(reason: String) {
        // 首次抑制：系统注册 NetworkCallback 后会立即回调当前网络状态，
        // 但这并不是"用户切换网络"，不应该往 UI 推"网络已切换"提示。
        // Dart 端 _DartLanBroadcaster._connectivityFirstEvent 也有同样处理。
        if (!firstNetworkEventSuppressed) {
            firstNetworkEventSuppressed = true
            // socket 重新 join（socket 此时可能还没 init 完，会无操作）
            Thread {
                try { rejoinMulticast() } catch (e: Exception) {
                    Log.w(TAG, "rejoinMulticast failed", e)
                }
            }.start()
            return
        }

        // 去重：800ms 内连续相同 reason 跳过（两个 callback 都 onAvailable 会重复）
        val now = System.currentTimeMillis()
        synchronized(this) {
            if (now - lastNetworkEventTs < networkEventDedupMs &&
                reason == lastNetworkEventReason
            ) {
                return
            }
            lastNetworkEventTs = now
            lastNetworkEventReason = reason
        }

        // 推 UI 提示给 Dart
        val event = mapOf(
            "type" to "network",
            "reason" to reason,
            "ts" to now,
        )
        postEvent(event)

        // 重新 join socket（在 socket thread 里执行，避免阻塞主线程）
        Thread {
            try {
                rejoinMulticast()
            } catch (e: Exception) {
                Log.w(TAG, "rejoinMulticast failed", e)
            }
        }.start()
    }

    // --------------------------- Socket ---------------------------

    @Synchronized
    private fun initSocketLocked() {
        val s = MulticastSocket(PORT)
        s.reuseAddress = true
        // MulticastSocket.loopbackMode: true = 禁用回环，false = 启用回环
        s.loopbackMode = false
        s.timeToLive = 64
        s.soTimeout = 0
        joinOnAllInterfaces(s)
        socket = s

        // flush 待发送队列
        val pending = synchronized(pendingQueue) {
            val copy = pendingQueue.toList()
            pendingQueue.clear()
            copy
        }
        for ((name, msg) in pending) {
            trySend(name, msg)
        }

        // 通知 Dart Service ready
        postEvent(mapOf("type" to "ready"))
    }

    private fun joinOnAllInterfaces(s: MulticastSocket) {
        val group = InetAddress.getByName(MULTICAST_IP)
        var joined = 0
        val ifaces = NetworkInterface.getNetworkInterfaces()
        while (ifaces.hasMoreElements()) {
            val iface = ifaces.nextElement()
            if (!iface.isUp || iface.isLoopback) continue
            // 只在 IPv4 接口上 join
            val addrs = iface.inetAddresses
            var hasIPv4 = false
            while (addrs.hasMoreElements()) {
                val a = addrs.nextElement()
                if (a is java.net.Inet4Address) {
                    hasIPv4 = true
                    break
                }
            }
            if (!hasIPv4) continue
            try {
                s.joinGroup(InetSocketAddress(group, PORT), iface)
                joined++
            } catch (e: Exception) {
                // 虚拟网卡等接口 join 失败很正常，忽略即可
            }
        }
        Log.i(TAG, "joined multicast on $joined interface(s)")
    }

    @Synchronized
    private fun rejoinMulticast() {
        val s = socket ?: return
        val group = InetAddress.getByName(MULTICAST_IP)
        // 先 leave 再 join（避免某些接口的旧成员资格残留）
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces()
            while (ifaces.hasMoreElements()) {
                val iface = ifaces.nextElement()
                if (!iface.isUp || iface.isLoopback) continue
                try {
                    s.leaveGroup(InetSocketAddress(group, PORT), iface)
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
        try {
            joinOnAllInterfaces(s)
        } catch (e: Exception) {
            Log.w(TAG, "rejoinMulticast join failed", e)
        }
    }

    private fun startReceivingLocked() {
        running = true
        val buf = ByteArray(64 * 1024)
        val thread = Thread {
            while (running) {
                val packet = DatagramPacket(buf, buf.size)
                try {
                    socket?.receive(packet) ?: break
                } catch (e: java.net.SocketException) {
                    if (!running) break
                    // socket 关闭或异常，继续循环（短暂休眠避免空转）
                    try { Thread.sleep(50) } catch (_: InterruptedException) { break }
                    continue
                } catch (e: Exception) {
                    if (!running) break
                    continue
                }
                val data = packet.data.copyOfRange(0, packet.length)
                handleReceived(data)
            }
        }
        thread.name = "lan-broadcast-recv"
        thread.isDaemon = true
        thread.start()
        receiveThread = thread
    }

    private fun handleReceived(data: ByteArray) {
        val str = try {
            String(data, StandardCharsets.UTF_8)
        } catch (_: Exception) {
            return
        }
        val json = try {
            JSONObject(str)
        } catch (_: Exception) {
            return
        }
        val name = json.optString("name", "")
        val msg = json.optString("msg", "")
        if (name.isEmpty() && msg.isEmpty()) return

        // 推给 Dart
        val event = mapOf(
            "type" to "message",
            "name" to name,
            "msg" to msg,
            "ts" to System.currentTimeMillis(),
        )
        postEvent(event)

        // 后台时同时发本地通知
        if (!isAppInForeground) {
            showLocalNotification(name, msg)
        }
    }

    private fun trySend(name: String, msg: String): Boolean {
        val s = socket ?: run {
            // socket 还没 ready，缓存到队列，等 initSocketLocked 后 flush
            synchronized(pendingQueue) {
                pendingQueue.add(name to msg)
            }
            return true
        }
        val json = JSONObject()
        json.put("name", name)
        json.put("msg", msg)
        val bytes = json.toString().toByteArray(StandardCharsets.UTF_8)
        val dest = DatagramPacket(
            bytes, bytes.size,
            InetAddress.getByName(MULTICAST_IP), PORT,
        )
        // 优先用绑定的 MulticastSocket 发（带 outgoing interface 信息最准）
        return try {
            s.send(dest)
            true
        } catch (e: Exception) {
            Log.w(TAG, "MulticastSocket.send failed, retry with ephemeral DatagramSocket", e)
            // 回退：用一个临时未绑定端口的 DatagramSocket 发送，
            // 让 OS 自动选择 outgoing interface，避免 MulticastSocket 路由失败。
            var ok = false
            var ds: java.net.DatagramSocket? = null
            try {
                ds = java.net.DatagramSocket()
                ds.broadcast = true
                ds.send(dest)
                ok = true
            } catch (e2: Exception) {
                Log.e(TAG, "fallback DatagramSocket send also failed", e2)
            } finally {
                try { ds?.close() } catch (_: Exception) {}
            }
            ok
        }
    }

    private fun showLocalNotification(name: String, msg: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notif = NotificationCompat.Builder(this, MSG_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(if (name.isEmpty()) "(匿名)" else name)
            .setContentText(msg)
            .setStyle(NotificationCompat.BigTextStyle().bigText(msg))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        // 用 name 的 hashCode 做 id，同一发送者的新消息覆盖旧的
        val id = name.hashCode() and 0x7FFFFFFF
        try {
            nm.notify(id, notif)
        } catch (e: Exception) {
            Log.w(TAG, "showLocalNotification failed", e)
        }
    }
}
