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
 * 绑定是异步的——未绑定时先把请求排队，连上后按顺序 flush。
 */
object OpenListBridge {
    private const val TAG = "OpenListBridge"
    private val main = Handler(Looper.getMainLooper())
    private val nextId = AtomicInteger(1)
    private val pending = mutableListOf<Pair<Int, String>>()
    private val waiters = ConcurrentHashMap<Int, MethodChannel.Result>()
    private var service: Messenger? = null
    private var bound = false

    private val replyHandler = object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(msg: Message) {
            val id = msg.arg1
            val result = waiters.remove(id) ?: return
            val response = msg.data?.getString(OpenListService.KEY_RESPONSE)
            val error = msg.data?.getString(OpenListService.KEY_ERROR)
            if (error != null) {
                result.error("openlist", error, null)
            } else if (response != null) {
                result.success(response)
            } else {
                result.error("openlist", "empty response from core", null)
            }
        }
    }
    private val replyMessenger = Messenger(replyHandler)

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = binder?.let { Messenger(it) }
            bound = true
            val queued = ArrayList(pending)
            pending.clear()
            for ((id, request) in queued) send(id, request)
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            bound = false
        }
    }

    private fun send(id: Int, request: String) {
        val messenger = service
        if (messenger == null) {
            resultError(id, "core service not connected")
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
        waiters.remove(id)?.error("openlist", message, null)
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(bound || service != null)
            "invoke" -> {
                val request = call.argument<String>("request")
                if (request.isNullOrEmpty()) {
                    result.error("invalid_request", "request is required", null)
                    return
                }
                val id = nextId.getAndIncrement()
                waiters[id] = result
                val context = appContext
                if (context == null) {
                    resultError(id, "application context unavailable")
                    return
                }
                if (bound && service != null) {
                    send(id, request)
                } else {
                    pending.add(id to request)
                    bind(context)
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
        try {
            val intent = android.content.Intent(context, OpenListService::class.java)
            context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        } catch (t: Throwable) {
            val queued = ArrayList(pending)
            pending.clear()
            for ((id, _) in queued) resultError(id, t.message ?: t.toString())
        }
    }
}
