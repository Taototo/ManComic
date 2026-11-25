package com.github.wgh136.venera

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import openlistcore.Openlistcore

/**
 * 网盘内核服务，跑在独立的 :openlist 进程。
 *
 * 为什么必须独立进程：内核是 gomobile 封装的 Go 库，内部带一份 Go runtime；
 * 主进程已经被 libXray 占了一份。一个进程塞两份 Go runtime 会在加载阶段直接崩，
 * 所以这里用进程边界把两份 runtime 物理隔开。
 *
 * AAR 已打补丁：内核自带的 gomobile 运行时包名 go.* → gx.*（.so 里的
 * Java_go_* 符号同步改名），so 名 libgojni → libopenlistjni。这样主进程用
 * go.Seq + libgojni，内核进程用 gx.Seq + libopenlistjni，互不干扰。
 *
 * 通信协议：主进程发一条 Message，what = MSG_INVOKE，data 里放
 * "request"（JSON 字符串）；replyTo 用来回传 "response" 或 "error"。
 *
 * 注意：回复消息必须带上请求的 arg1，否则主进程的 waiters 找不到对应请求，
 * 调用方会永久等待（这就是之前"一直加载、连不上"的根因）。
 */
class OpenListService : Service() {
    companion object {
        const val MSG_INVOKE = 1
        const val MSG_PING = 2
        const val KEY_REQUEST = "request"
        const val KEY_RESPONSE = "response"
        const val KEY_ERROR = "error"
        const val PONG = "pong"
    }

    private val workThread = HandlerThread("openlist-core").also { it.start() }
    private val workHandler = Handler(workThread.looper) { msg -> handleMessage(msg); true }
    private val messenger = Messenger(workHandler)

    /** 内核 so 是否加载成功；加载失败时所有调用直接报错，避免无谓等待。 */
    @Volatile
    private var loadError: String? = null

    override fun onCreate() {
        super.onCreate()
        try {
            System.loadLibrary("openlistjni")
        } catch (t: Throwable) {
            loadError = "内核加载失败：${t.javaClass.simpleName}: ${t.message}"
        }
    }

    private fun handleMessage(msg: Message) {
        val replyTo = msg.replyTo ?: return
        when (msg.what) {
            // 只证明进程活着，不碰内核——绑定成功后先确认这一点。
            MSG_PING -> reply(replyTo, msg.arg1, response = PONG)
            MSG_INVOKE -> {
                val request = msg.data?.getString(KEY_REQUEST) ?: return
                val error = loadError
                if (error != null) {
                    reply(replyTo, msg.arg1, error = error)
                    return
                }
                try {
                    reply(replyTo, msg.arg1, response = Openlistcore.invoke(request))
                } catch (t: Throwable) {
                    // ExceptionInInitializerError / UnsatisfiedLinkError 都在这里兜住。
                    val detail = buildString {
                        append(t.javaClass.simpleName)
                        val message = t.message
                        if (!message.isNullOrBlank()) append(": ").append(message)
                        val cause = t.cause
                        if (cause != null && cause !== t) {
                            append(" <- ").append(cause.javaClass.simpleName)
                            val causeMessage = cause.message
                            if (!causeMessage.isNullOrBlank()) append(": ").append(causeMessage)
                        }
                    }
                    // 只有"符号/类加载"这类致命错误才永久标记，避免一次网络
                    // 失败把整个内核判死。
                    val fatal = t is UnsatisfiedLinkError ||
                        t is ExceptionInInitializerError ||
                        t is NoClassDefFoundError
                    val message = "内核调用失败：$detail"
                    if (fatal) loadError = message
                    reply(replyTo, msg.arg1, error = message)
                }
            }
        }
    }

    private fun reply(
        replyTo: Messenger,
        requestId: Int,
        response: String? = null,
        error: String? = null,
    ) {
        val message = Message.obtain(null, MSG_INVOKE).apply {
            // 关键：把请求 id 带回去，否则主进程无法把结果交给调用方。
            arg1 = requestId
            data = Bundle().apply {
                if (response != null) putString(KEY_RESPONSE, response)
                if (error != null) putString(KEY_ERROR, error)
            }
        }
        try {
            replyTo.send(message)
        } catch (_: Throwable) {
            // 主进程已经退出，忽略。
        }
    }

    override fun onBind(intent: Intent): IBinder = messenger.binder

    override fun onDestroy() {
        workThread.quitSafely()
        super.onDestroy()
    }
}
