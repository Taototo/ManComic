package com.github.wgh136.venera

import android.app.Service
import android.content.Intent
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
 * 另外 AAR 已打补丁：包名 go.* → openlistgo.*、so 名 libgojni → libopenlistjni，
 * 避免同进程/打包时的符号冲突。
 *
 * 通信协议：主进程发一条 Message，what = MSG_INVOKE，data 里放
 * "request"（JSON 字符串）；replyTo 用来回传 "response" 或 "error"。
 */
class OpenListService : Service() {
    companion object {
        const val MSG_INVOKE = 1
        const val KEY_REQUEST = "request"
        const val KEY_RESPONSE = "response"
        const val KEY_ERROR = "error"
    }

    private val workThread = HandlerThread("openlist-core").also { it.start() }
    private val workHandler = Handler(workThread.looper) { msg -> handleMessage(msg); true }
    private val messenger = Messenger(workHandler)

    private fun handleMessage(msg: Message) {
        when (msg.what) {
            MSG_INVOKE -> {
                val request = msg.data?.getString(KEY_REQUEST)
                val replyTo = msg.replyTo
                if (request == null || replyTo == null) return
                try {
                    val response = Openlistcore.invoke(request)
                    val reply = Message.obtain(null, MSG_INVOKE).apply {
                        data = android.os.Bundle().apply { putString(KEY_RESPONSE, response) }
                    }
                    replyTo.send(reply)
                } catch (t: Throwable) {
                    val reply = Message.obtain(null, MSG_INVOKE).apply {
                        data = android.os.Bundle().apply { putString(KEY_ERROR, t.message ?: t.toString()) }
                    }
                    try { replyTo.send(reply) } catch (_: Exception) {}
                }
            }
        }
    }

    override fun onBind(intent: Intent): IBinder = messenger.binder

    override fun onDestroy() {
        workThread.quitSafely()
        super.onDestroy()
    }
}
