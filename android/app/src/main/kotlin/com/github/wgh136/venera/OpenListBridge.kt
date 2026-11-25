package com.github.wgh136.venera

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * 主进程侧：把 Dart 的 invoke 请求转发给 :openlist 进程的内核服务。
 *
 * 绑定是异步的——未绑定时先把请求排队，连上后按顺序 flush。
 *
 * 所有等待都必须有上限：内核进程可能启动失败、被杀、或者调用本身卡死。
 * 之前没有任何超时，一旦回复丢失，Dart 侧的 Future 永远不完成，界面上就是
 * "一直转圈、连不上"。现在每个请求都有超时，绑不上也有超时，一律返回错误。
 */
object OpenListBridge {
    private const val INVOKE_TIMEOUT_MS = 25_000L
    private const val INITIALIZE_TIMEOUT_MS = 60_000L
    private const val BIND_TIMEOUT_MS = 12_000L

    /** 内核进程连续崩溃这么多次后不再重试，直接报错。 */
    private const val MAX_DEATHS = 2

    private val main = Handler(Looper.getMainLooper())
    private val nextId = AtomicInteger(1)
    private val pending = mutableListOf<Pair<Int, String>>()
    private val waiters = ConcurrentHashMap<Int, Waiter>()
    private var service: Messenger? = null
    @Volatile
    private var bound = false
    private var binding = false
    private var deaths = 0

    /** 内核彻底不可用时的固定错误（例如反复崩溃），后续请求快速失败。 */
    private var fatalError: String? = null

    private class Waiter(
        val result: MethodChannel.Result,
        val timeout: Runnable,
    )

    private val replyHandler = object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(msg: Message) {
            val id = msg.arg1
            val waiter = waiters.remove(id) ?: return
            main.removeCallbacks(waiter.timeout)
            deaths = 0
            val response = msg.data?.getString(OpenListService.KEY_RESPONSE)
            val error = msg.data?.getString(OpenListService.KEY_ERROR)
            when {
                error != null -> waiter.result.error("openlist", error, null)
                response != null -> waiter.result.success(response)
                else -> waiter.result.error("openlist", "empty response from core", null)
            }
        }
    }
    private val replyMessenger = Messenger(replyHandler)

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            if (binder == null) {
                failAll("内核服务绑定失败（binder 为空）")
                return
            }
            service = Messenger(binder)
            bound = true
            binding = false
            main.removeCallbacks(bindTimeout)
            ping()
            val queued = ArrayList(pending)
            pending.clear()
            for ((id, request) in queued) send(id, request)
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            onCoreGone("内核服务已断开")
        }

        override fun onBindingDied(name: ComponentName?) {
            onCoreGone("内核进程已崩溃")
        }

        override fun onNullBinding(name: ComponentName?) {
            onCoreGone("内核服务未能启动")
        }
    }

    private val bindTimeout = Runnable { failAll("内核服务连接超时，请稍后重试") }

    private fun onCoreGone(reason: String) {
        service = null
        bound = false
        binding = false
        main.removeCallbacks(bindTimeout)
        deaths++
        failAll(reason)
        if (deaths >= MAX_DEATHS) {
            fatalError = "$reason（内核连续 ${deaths} 次启动失败）"
        }
    }

    /** 绑定成功后探活：只证明进程活着，不碰内核。 */
    private fun ping() {
        val messenger = service ?: return
        try {
            val message = Message.obtain(null, OpenListService.MSG_PING).apply {
                arg1 = 0
                data = Bundle()
                replyTo = replyMessenger
            }
            messenger.send(message)
        } catch (_: Throwable) {
            // 探活失败不影响正式请求，正式请求自己会超时。
        }
    }

    private fun send(id: Int, request: String) {
        val messenger = service
        if (messenger == null) {
            resultError(id, "内核服务未连接")
            return
        }
        try {
            val msg = Message.obtain(null, OpenListService.MSG_INVOKE).apply {
                arg1 = id
                data = Bundle().apply { putString(OpenListService.KEY_REQUEST, request) }
                replyTo = replyMessenger
            }
            messenger.send(msg)
        } catch (t: Throwable) {
            resultError(id, t.message ?: t.toString())
        }
    }

    private fun resultError(id: Int, message: String) {
        val waiter = waiters.remove(id) ?: return
        main.removeCallbacks(waiter.timeout)
        waiter.result.error("openlist", message, null)
    }

    private fun failAll(message: String) {
        pending.clear()
        for (id in ArrayList(waiters.keys)) resultError(id, message)
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // The core AAR is bundled with every Android build, so the bridge
            // itself is always present. Do NOT gate this on `bound`: binding
            // only happens on the first `invoke`, so checking it here would
            // always report false and hide the whole feature. Native init
            // failures surface as `invoke` errors instead.
            "available" -> result.success(true)
            "invoke" -> {
                val request = call.argument<String>("request")
                if (request.isNullOrEmpty()) {
                    result.error("invalid_request", "request is required", null)
                    return
                }
                val error = fatalError
                if (error != null) {
                    result.error("openlist", error, null)
                    return
                }
                val context = appContext
                if (context == null) {
                    result.error("openlist", "application context unavailable", null)
                    return
                }
                val id = nextId.getAndIncrement()
                val timeoutMs = if (request.contains("\"initialize\"")) {
                    INITIALIZE_TIMEOUT_MS
                } else {
                    INVOKE_TIMEOUT_MS
                }
                val timeout = Runnable {
                    if (waiters.remove(id) != null) {
                        result.error(
                            "openlist",
                            "内核响应超时（${timeoutMs / 1000} 秒），请检查网络或代理设置",
                            null,
                        )
                    }
                }
                waiters[id] = Waiter(result, timeout)
                main.postDelayed(timeout, timeoutMs)
                if (bound && service != null) {
                    send(id, request)
                } else {
                    pending.add(id to request)
                    if (!binding) bind(context)
                }
            }
            else -> result.notImplemented()
        }
    }

    @Volatile
    private var appContext: Context? = null

    fun attach(context: Context) {
        appContext = context.applicationContext
    }

    private fun bind(context: Context) {
        binding = true
        main.removeCallbacks(bindTimeout)
        main.postDelayed(bindTimeout, BIND_TIMEOUT_MS)
        try {
            val intent = android.content.Intent(context, OpenListService::class.java)
            val ok = context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
            if (!ok) {
                binding = false
                main.removeCallbacks(bindTimeout)
                failAll("无法启动网盘内核服务")
            }
        } catch (t: Throwable) {
            binding = false
            main.removeCallbacks(bindTimeout)
            failAll(t.message ?: t.toString())
        }
    }
}
