package com.github.wgh136.venera

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import libXray.LibXray

/**
 * libXray（Xray-core 的 gomobile 封装）的 Dart 侧入口。
 *
 * 这里只做一件事：把 Dart 递过来的 `{method, payload}` 转发给
 * `LibXray.invoke`，再把原始 JSON 字符串原样退回。
 *
 * 为什么不在 app 里做 VpnService：本项目要的是「只代理自己 + 关掉 app 就干净」。
 * 起一个进程内的 Xray 实例、只监听 127.0.0.1 的 http 入站，自己的网络层把代理
 * 指过去，就同时满足两条——别的 app 不知道这个端口存在，进程一死端口就没了，
 * 不需要任何清理逻辑。VpnService 反而要常驻通知、要在系统里挂一个 VPN 图标，
 * 还被 START_STICKY 之类的保活逻辑拖着不肯死。
 */
object XrayBridge {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var loaded = false

    @Volatile
    private var loadError: String? = null

    private fun ensureLoaded(): String? {
        if (loaded) return null
        loadError?.let { return it }
        return try {
            // 触发 gobind 的静态初始化，把 libgojni.so 加载进来。
            // 一个进程只能有一份 Go runtime，加第二个 Go/gomobile 库会在这一步
            // 直接崩，所以这里失败必须能被 Dart 侧看见、并且把功能藏起来。
            LibXray.touch()
            loaded = true
            null
        } catch (t: Throwable) {
            val msg = t.message ?: t.toString()
            loadError = msg
            msg
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 懒加载自检：核心在不在、能不能加载。失败就把「内置代理」整个藏掉。
            "available" -> executor.execute {
                val err = ensureLoaded()
                main.post { result.success(err == null) }
            }

            "invoke" -> {
                val method = call.argument<String>("method")
                val payload = call.argument<String>("payload") ?: "{}"
                if (method.isNullOrEmpty()) {
                    result.success(errorJson("missing method"))
                    return
                }
                // invoke 是同步阻塞的（runXray 尤其），绝不能放主线程。
                executor.execute {
                    val out = invokeRaw(method, payload)
                    main.post { result.success(out) }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun invokeRaw(method: String, payload: String): String {
        ensureLoaded()?.let { return errorJson(it) }
        return try {
            LibXray.invoke(
                "{\"apiVersion\":3,\"method\":\"$method\",\"payload\":$payload}"
            )
        } catch (t: Throwable) {
            errorJson(t.message ?: t.toString())
        }
    }

    private fun errorJson(message: String): String {
        val escaped = message
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", " ")
            .replace("\r", " ")
        return "{\"success\":false,\"error\":\"$escaped\"}"
    }
}
