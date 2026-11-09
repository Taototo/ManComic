package com.github.wgh136.venera

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log
import android.view.Display
import android.view.KeyEvent
import androidx.activity.result.ActivityResultCallback
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import dev.flutter.packages.file_selector_android.FileUtils
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterFragmentActivity() {
    var volumeListen = VolumeListen()
    var listening = false

    private val storageRequestCode = 0x10
    private var storagePermissionRequest: ((Boolean) -> Unit)? = null

    private val nextLocalRequestCode = AtomicInteger()

    private val sharedTexts = ArrayList<String>()

    private var textShareHandler: ((String) -> Unit)? = null

    /// 用户请求的帧率上限（null 表示跟随屏幕最高刷新率）。
    /// 切到后台再回来时系统会重置窗口的帧率提示，所以这个值要记住以便重放。
    private var frameRateTarget: Double? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        ensureLauncherEntry()
        applyPendingIcon()

        if (intent?.action == Intent.ACTION_SEND) {
            if (intent.type == "text/plain") {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (text != null)
                    handleSharedText(text)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == Intent.ACTION_SEND) {
            if (intent.type == "text/plain") {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (text != null)
                    handleSharedText(text)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // 系统（尤其国产 ROM 的省电策略）会在切后台后把窗口帧率重置回 60，
        // 回到前台重新申请一次，否则只有冷启动那一下是高刷。
        applyFrameRate(frameRateTarget)
    }

    @Suppress("DEPRECATION")
    private fun currentDisplay(): Display? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            windowManager.defaultDisplay
        }
    }

    /// 与当前分辨率相同的模式里最高的刷新率。
    ///
    /// 只在同分辨率内挑，避免为了高刷把渲染分辨率也换掉（那会让界面发虚）。
    private fun highestRefreshRate(display: Display): Double {
        val current = display.mode
        var best = current.refreshRate.toDouble()
        for (mode in display.supportedModes) {
            if (mode.physicalWidth == current.physicalWidth &&
                mode.physicalHeight == current.physicalHeight &&
                mode.refreshRate > best
            ) {
                best = mode.refreshRate.toDouble()
            }
        }
        return best
    }

    /// 申请屏幕帧率。
    ///
    /// 三路一起走，覆盖不同年代的系统：
    /// - `LayoutParams.preferredRefreshRate`（API 21+）最老的"我想跑这个帧率"
    ///   提示，很多 ROM 的省电策略从这里取数；
    /// - `preferredDisplayModeId`（API 23+）指定具体显示模式，那些只认模式、
    ///   不看提示的 ROM 靠它；
    /// - `View.setRequestedFrameRate`（较新的 API）是系统推荐的现代写法，
    ///   但不同 SDK 版本未必存在，所以用反射调用，缺失就跳过。
    ///
    /// 三条都是"请求"而不是命令，系统可以因为省电/热控拒绝，最终以
    /// [displayInfo] 回报的实际刷新率为准。
    ///
    /// [target] 为 null 表示用屏幕支持的最高值。
    private fun applyFrameRate(target: Double?) {
        frameRateTarget = target
        try {
            val display = currentDisplay() ?: return
            val maxRate = highestRefreshRate(display)
            val rate = (target ?: maxRate).coerceIn(30.0, maxRate)

            val current = display.mode
            val mode = display.supportedModes
                .filter {
                    it.physicalWidth == current.physicalWidth &&
                        it.physicalHeight == current.physicalHeight
                }
                .minByOrNull { kotlin.math.abs(it.refreshRate - rate) }

            val lp = window.attributes
            var changed = false
            if (lp.preferredRefreshRate != rate.toFloat()) {
                lp.preferredRefreshRate = rate.toFloat()
                changed = true
            }
            if (mode != null && lp.preferredDisplayModeId != mode.modeId) {
                lp.preferredDisplayModeId = mode.modeId
                changed = true
            }
            if (changed) {
                window.attributes = lp
            }

            requestViewFrameRate(rate)
        } catch (e: Exception) {
            // 部分设备/ROM 会拒绝设置显示模式（例如固定 60Hz 的省电模式），
            // 这里只记录，不影响应用运行。
            Log.e("Venera", "applyFrameRate failed", e)
        }
    }

    /// `View.setRequestedFrameRate` 只在较新的 SDK 上存在，且各版本签名一致，
    /// 用反射调可以避免为它抬 minSdk；调不到就当作没有这个能力。
    private fun requestViewFrameRate(rate: Double) {
        try {
            val view = window.decorView
            val method = view.javaClass.getMethod(
                "setRequestedFrameRate",
                Float::class.javaPrimitiveType
            )
            method.invoke(view, rate.toFloat())
        } catch (_: Throwable) {
            // 老系统没有这个方法，前两路已经够用。
        }
    }

    /// 当前显示信息，供设置页与实际帧率叠加层使用。
    private fun displayInfo(): Map<String, Any> {
        val display = currentDisplay()
        if (display == null) {
            return mapOf(
                "refreshRate" to 60.0,
                "maxRefreshRate" to 60.0,
                "supported" to listOf(60.0),
            )
        }
        val rates = display.supportedModes
            .map { it.refreshRate.toDouble() }
            .distinct()
            .sorted()
        return mapOf(
            "refreshRate" to display.refreshRate.toDouble(),
            "maxRefreshRate" to highestRefreshRate(display),
            "supported" to rates,
        )
    }

    private fun handleSharedText(text: String) {
        if (textShareHandler != null) {
            textShareHandler?.invoke(text)
        } else {
            sharedTexts.add(text)
        }
    }

    private fun <I, O> startContractForResult(
        contract: ActivityResultContract<I, O>,
        input: I,
        callback: ActivityResultCallback<O>
    ) {
        val key = "activity_rq_for_result#${nextLocalRequestCode.getAndIncrement()}"
        val registry = activityResultRegistry
        var launcher: ActivityResultLauncher<I>? = null
        val observer = object : LifecycleEventObserver {
            override fun onStateChanged(source: LifecycleOwner, event: Lifecycle.Event) {
                if (Lifecycle.Event.ON_DESTROY == event) {
                    launcher?.unregister()
                    lifecycle.removeObserver(this)
                }
            }
        }
        lifecycle.addObserver(observer)
        val newCallback = ActivityResultCallback<O> {
            launcher?.unregister()
            lifecycle.removeObserver(observer)
            callback.onActivityResult(it)
        }
        launcher = registry.register(key, contract, newCallback)
        launcher.launch(input)
    }

    private var vibrator: Vibrator? = null

    /// 一段极短的定振幅震动。
    ///
    /// 设备支持振幅控制时用 [amplitude]；不支持时退回系统默认振幅——
    /// 至少时长比 CLOCK_TICK 短，听感上还是更轻。
    private fun hapticTick(durationMs: Int, amplitude: Int) {
        try {
            val v = vibrator ?: run {
                val resolved: Vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val manager =
                        getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                    manager.defaultVibrator
                } else {
                    @Suppress("DEPRECATION")
                    getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                }
                vibrator = resolved
                resolved
            }
            if (!v.hasVibrator()) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val effect = if (v.hasAmplitudeControl()) {
                    VibrationEffect.createOneShot(durationMs.toLong(), amplitude)
                } else {
                    VibrationEffect.createOneShot(
                        durationMs.toLong(),
                        VibrationEffect.DEFAULT_AMPLITUDE
                    )
                }
                v.vibrate(effect)
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(durationMs.toLong())
            }
        } catch (e: Exception) {
            Log.w("Venera", "haptic tick failed", e)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "venera/method_channel"
        ).setMethodCallHandler { call, res ->
            when (call.method) {
                "getProxy" -> res.success(getProxy())
                "getAppIcon" -> res.success(getAppIcon())
                "setAppIcon" -> {
                    val key = call.argument<String>("key") ?: "default"
                    val ok = try {
                        // 只记录选择，真正的组件切换放到下次启动时执行。
                        // 运行中启用/禁用 launcher alias 会让部分系统直接结束当前任务（表现为闪退）。
                        savePendingIcon(key)
                        true
                    } catch (e: Exception) {
                        Log.e("Venera", "setAppIcon failed", e)
                        false
                    }
                    res.success(ok)
                }
                "closeApp" -> {
                    try {
                        // 退出前把待切换的图标应用到桌面，用户从桌面重新打开即为新图标
                        closeApp()
                        res.success(true)
                    } catch (e: Exception) {
                        Log.e("Venera", "closeApp failed", e)
                        res.success(false)
                    }
                }
                "getBrightness" -> res.success(getBrightness())
                "setBrightness" -> {
                    val value = call.argument<Double>("value")?.toFloat() ?: 1f
                    setWindowBrightness(value)
                    res.success(null)
                }
                "resetBrightness" -> {
                    setWindowBrightness(-1f)
                    res.success(null)
                }
                "setScreenOn" -> {
                    val set = call.argument<Boolean>("set") ?: false
                    if (set) {
                        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    res.success(null)
                }

                "installApk" -> {
                    // 应用内更新：通过 FileProvider 把 APK 交给系统安装器。
                    // 首次安装时系统会自动引导用户授予「安装未知应用」权限。
                    val path = call.argument<String>("path")
                    if (path == null) {
                        res.success(false)
                    } else {
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                Log.e("Venera", "installApk: file not found: $path")
                                res.success(false)
                            } else {
                                val uri = FileProvider.getUriForFile(
                                    this,
                                    "$packageName.fileprovider",
                                    file
                                )
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/vnd.android.package-archive")
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(intent)
                                res.success(true)
                            }
                        } catch (e: Exception) {
                            Log.e("Venera", "installApk failed", e)
                            res.success(false)
                        }
                    }
                }

                "startUpdateDownloadService" -> {
                    // 应用内更新：下载期间挂前台服务，回到桌面也不会被系统冻结
                    UpdateDownloadService.start(
                        this,
                        call.argument<String>("title") ?: "Downloading update",
                        call.argument<String>("text") ?: "",
                        call.argument<Int>("progress") ?: -1
                    )
                    res.success(true)
                }

                "updateUpdateDownloadService" -> {
                    UpdateDownloadService.update(
                        this,
                        call.argument<String>("title") ?: "Downloading update",
                        call.argument<String>("text") ?: "",
                        call.argument<Int>("progress") ?: -1
                    )
                    res.success(true)
                }

                "stopUpdateDownloadService" -> {
                    UpdateDownloadService.stop(this)
                    res.success(true)
                }

                // 漫画下载：同更新包那套，只是多了把 wakelock（见
                // ComicDownloadService），锁屏后下载才不会被挂起。
                "startDownloadService" -> {
                    ComicDownloadService.start(
                        this,
                        call.argument<String>("title") ?: "Downloading",
                        call.argument<String>("text") ?: "",
                        call.argument<Int>("progress") ?: -1
                    )
                    res.success(true)
                }

                "updateDownloadService" -> {
                    ComicDownloadService.update(
                        this,
                        call.argument<String>("title") ?: "Downloading",
                        call.argument<String>("text") ?: "",
                        call.argument<Int>("progress") ?: -1
                    )
                    res.success(true)
                }

                "stopDownloadService" -> {
                    ComicDownloadService.stop(this)
                    res.success(true)
                }

                "getDirectoryPath" -> {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    startContractForResult(ActivityResultContracts.StartActivityForResult(), intent) { activityResult ->
                        if (activityResult.resultCode != Activity.RESULT_OK) {
                            res.success(null)
                            return@startContractForResult
                        }
                        val pickedDirectoryUri = activityResult.data?.data
                        if (pickedDirectoryUri == null)
                            res.success(null)
                        else
                            onPickedDirectory(pickedDirectoryUri, res)
                    }
                }

                else -> res.notImplemented()
            }
        }

        // 屏幕刷新率：Dart 侧读取实际值、按用户选择申请帧率。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "venera/display"
        ).setMethodCallHandler { call, res ->
            when (call.method) {
                "applyFrameRate" -> {
                    applyFrameRate(call.argument<Double>("target"))
                    res.success(displayInfo())
                }

                "getDisplayInfo" -> res.success(displayInfo())
                else -> res.notImplemented()
            }
        }

        // 触感：底栏点一下的反馈。
        //
        // 系统那一下（CLOCK_TICK）的强度和时长是国内 ROM 说了算的，
        // 普遍偏重；这里自己发一段定振幅短震，才能真正「轻一点」。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "venera/haptics"
        ).setMethodCallHandler { call, res ->
            when (call.method) {
                "tick" -> {
                    val ms = (call.argument<Int>("durationMs") ?: 8).coerceIn(1, 40)
                    val amp = (call.argument<Int>("amplitude") ?: 45).coerceIn(1, 255)
                    hapticTick(ms, amp)
                    res.success(null)
                }

                else -> res.notImplemented()
            }
        }

        val channel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/volume")
        channel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    listening = true
                    volumeListen.onUp = {
                        events.success(1)
                    }
                    volumeListen.onDown = {
                        events.success(2)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    listening = false
                }
            })

        val storageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/storage")
        storageChannel.setMethodCallHandler { _, res ->
            requestStoragePermission { result ->
                res.success(result)
            }
        }

        val selectFileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/select_file")
        selectFileChannel.setMethodCallHandler { req, res ->
            val mimeType = req.arguments<String>()
            openFile(res, mimeType!!)
        }

        val shareTextChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "venera/text_share")
        shareTextChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    textShareHandler = {text ->
                        events.success(text)
                    }
                    if (sharedTexts.isNotEmpty()) {
                        for (text in sharedTexts) {
                            events.success(text)
                        }
                        sharedTexts.clear()
                    }
                }

                override fun onCancel(arguments: Any?) {
                    textShareHandler = null
                }
            })
    }

    private fun getProxy(): String {
        val host = System.getProperty("http.proxyHost")
        val port = System.getProperty("http.proxyPort")
        return if (host != null && port != null) {
            "$host:$port"
        } else {
            "No Proxy"
        }
    }

    /// 内置图标 -> AndroidManifest 中对应 activity-alias 的类名（相对包名）
    /// 注意：这里的组件名一旦发布就不要随意改名/删除，系统会持久化它们的启用状态，
    /// 组件消失会让桌面上对应的图标失效。
    private val iconAliases = linkedMapOf(
        "default" to "Icon1",
        "classic" to "Icon2",
        "neon" to "Icon4",
        "cat" to "Icon5",
        "logo" to "Icon6"
    )

    private fun aliasComponent(alias: String) = ComponentName(this, "$packageName.$alias")

    /// 某个 alias 当前是否真的能作为桌面入口。
    /// 状态为 DEFAULT 时以 manifest 声明为准：只有 Icon1 默认启用。
    private fun isAliasActive(alias: String): Boolean {
        val state = try {
            packageManager.getComponentEnabledSetting(aliasComponent(alias))
        } catch (e: Exception) {
            return false
        }
        return when (state) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> alias == "Icon1"
            else -> false
        }
    }

    /// 返回当前启用的图标 key；没有任何桌面入口时返回 null。
    private fun getAppIcon(): String? {
        for ((key, alias) in iconAliases) {
            if (isAliasActive(alias)) return key
        }
        return null
    }

    /// 启用目标图标的 alias 并禁用其余 alias。
    /// 先启用后禁用，避免中间态出现"没有任何桌面入口"。
    private fun setAppIcon(key: String) {
        val target = if (iconAliases.containsKey(key)) key else "default"
        val pm = packageManager
        val ordered = iconAliases.entries.sortedBy { if (it.key == target) 0 else 1 }
        for ((k, alias) in ordered) {
            val component = aliasComponent(alias)
            val desired = if (k == target) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            if (pm.getComponentEnabledSetting(component) != desired) {
                pm.setComponentEnabledSetting(component, desired, PackageManager.DONT_KILL_APP)
            }
        }
    }

    /// 自愈：组件启用状态会被系统持久化，升级后可能出现"所有 alias 都被禁用"
    /// （例如之前选中的图标在新版本里被移除），此时桌面完全没有入口。
    /// 这里保证任何一次启动后至少有一个可用的 launcher。
    private fun ensureLauncherEntry() {
        try {
            if (iconAliases.values.any { isAliasActive(it) }) return
            Log.w("Venera", "no launcher alias enabled, restoring default")
            packageManager.setComponentEnabledSetting(
                aliasComponent("Icon1"),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP
            )
        } catch (e: Exception) {
            Log.e("Venera", "ensureLauncherEntry failed", e)
        }
    }

    private fun iconPrefs() = getSharedPreferences("app_icon_switch", MODE_PRIVATE)

    /// 记录用户选择的图标，等待下次冷启动时切换。
    private fun savePendingIcon(key: String) {
        iconPrefs().edit().putString("pending", key).apply()
    }

    private fun pendingIconKey(): String? = iconPrefs().getString("pending", null)

    /// 在启动最早期切换 launcher 组件：此时没有用户可见的运行中任务，
    /// 即使系统强制重启进程也不会被感知成闪退。
    private fun applyPendingIcon() {
        val key = pendingIconKey() ?: return
        try {
            if (getAppIcon() != key) {
                setAppIcon(key)
            }
        } catch (e: Exception) {
            Log.e("Venera", "applyPendingIcon failed", e)
        } finally {
            iconPrefs().edit().remove("pending").apply()
        }
    }

    /// 直接关闭应用，并在关闭前把待切换的图标应用到桌面。
    ///
    /// 用于图标切换弹窗里的「立即重启」：不再重启到新任务的启动页
    /// （那会让用户先看一遍加载画面），而是就地退出；
    /// 下次从桌面打开时就是新图标。组件切换本来就有
    /// 「运行中执行可能被系统杀任务」的风险，这里反正在退出，无感。
    private fun closeApp() {
        try {
            applyPendingIcon()
        } catch (e: Exception) {
            Log.e("Venera", "closeApp: applyPendingIcon failed", e)
        }
        finishAffinity()
    }

    /// 当前生效的屏幕亮度（0..1）。优先取本窗口的覆盖值，其次取系统亮度。
    private fun getBrightness(): Double {
        val override = window?.attributes?.screenBrightness ?: -1f
        if (override >= 0f) {
            return override.toDouble().coerceIn(0.0, 1.0)
        }
        return systemBrightness().toDouble()
    }

    /// 系统亮度（0..1）。开启自动亮度时这个值会随环境光变化。
    private fun systemBrightness(): Float {
        val sys = try {
            Settings.System.getInt(
                contentResolver,
                Settings.System.SCREEN_BRIGHTNESS,
                128
            )
        } catch (e: Exception) {
            128
        }
        return (sys / 255f).coerceIn(0.01f, 1f)
    }

    /// 设置本窗口亮度。[value] 为 0.01..1 表示绝对亮度，传负数表示取消覆盖、交还系统。
    ///
    /// 只改 Window 的覆盖值，不写系统亮度设置，所以不影响其他应用；
    /// 也不会去监听系统亮度，避免自动亮度与本应用来回抢夺导致的忽明忽暗。
    private fun setWindowBrightness(value: Float) {
        runOnUiThread {
            try {
                val lp = window.attributes
                lp.screenBrightness = if (value < 0f) {
                    android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                } else {
                    value.coerceIn(0.01f, 1f)
                }
                window.attributes = lp
            } catch (e: Exception) {
                Log.e("Venera", "setWindowBrightness failed", e)
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (listening) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeListen.down()
                    return true
                }

                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeListen.up()
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    /// Ensure that the directory is accessible by dart:io
    private fun onPickedDirectory(uri: Uri, result: MethodChannel.Result) {
        if (hasStoragePermission()) {
            var plain = uri.toString()
            if(plain.contains("%3A")) {
                plain = Uri.decode(plain)
            }
            val externalStoragePrefix = "content://com.android.externalstorage.documents/tree/primary:";
            if(plain.startsWith(externalStoragePrefix)) {
                val path = plain.substring(externalStoragePrefix.length)
                result.success(Environment.getExternalStorageDirectory().absolutePath + "/" + path)
            }
            // The uri cannot be parsed to plain path, use copy method
        }
        // dart:io cannot access the directory without permission.
        // so we need to copy the directory to cache directory
        val contentResolver = contentResolver
        var tmp = cacheDir
        var dirName = DocumentFile.fromTreeUri(this, uri)?.name
        tmp = File(tmp, dirName!!)
        if(tmp.exists()) {
            tmp.deleteRecursively()
        }
        tmp.mkdir()
        Thread {
            try {
                copyDirectory(contentResolver, uri, tmp)
                result.success(tmp.absolutePath)
            }
            catch (e: Exception) {
                result.error("copy error", e.message, null)
            }
        }.start()

    }

    private fun copyDirectory(resolver: ContentResolver, srcUri: Uri, destDir: File) {
        val src = DocumentFile.fromTreeUri(this, srcUri) ?: return
        for (file in src.listFiles()) {
            if (file.isDirectory) {
                val newDir = File(destDir, file.name!!)
                newDir.mkdir()
                copyDirectory(resolver, file.uri, newDir)
            } else {
                val newFile = File(destDir, file.name!!)
                resolver.openInputStream(file.uri)?.use { input ->
                    FileOutputStream(newFile).use { output ->
                        input.copyTo(output, bufferSize = DEFAULT_BUFFER_SIZE)
                        output.flush()
                    }
                }
            }
        }
    }

    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED && ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            Environment.isExternalStorageManager()
        }
    }

    private fun requestStoragePermission(result: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            val readPermission = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED

            val writePermission = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED

            if (!readPermission || !writePermission) {
                storagePermissionRequest = result
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(
                        Manifest.permission.READ_EXTERNAL_STORAGE,
                        Manifest.permission.WRITE_EXTERNAL_STORAGE
                    ),
                    storageRequestCode
                )
            } else {
                result(true)
            }
        } else {
            if (!Environment.isExternalStorageManager()) {
                try {
                    val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                    intent.addCategory("android.intent.category.DEFAULT")
                    intent.data = Uri.parse("package:$packageName")
                    startContractForResult(ActivityResultContracts.StartActivityForResult(), intent){ _ ->
                        result(Environment.isExternalStorageManager())
                    }
                } catch (e: Exception) {
                    result(false)
                }
            } else {
                result(true)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == storageRequestCode) {
            storagePermissionRequest?.invoke(grantResults.all {
                it == PackageManager.PERMISSION_GRANTED
            })
            storagePermissionRequest = null
        }
    }

    private fun openFile(result: MethodChannel.Result, mimeType: String) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
        intent.addCategory(Intent.CATEGORY_OPENABLE)
        intent.type = mimeType
        startContractForResult(ActivityResultContracts.StartActivityForResult(), intent){ activityResult ->
            if (activityResult.resultCode != Activity.RESULT_OK) {
                result.success(null)
                return@startContractForResult
            }
            val uri = activityResult.data?.data
            if (uri == null) {
                result.success(null)
                return@startContractForResult
            }
            val contentResolver = contentResolver
            val file = DocumentFile.fromSingleUri(this, uri)
            if (file == null) {
                result.success(null)
                return@startContractForResult
            }
            val fileName = file.name
            if (fileName == null) {
                result.success(null)
                return@startContractForResult
            }
            if(hasStoragePermission()) {
                try {
                    val filePath = FileUtils.getPathFromUri(this, uri)
                    result.success(filePath)
                    return@startContractForResult
                }
                catch (e: Exception) {
                    // ignore
                }
            }
            // use copy method
            val tmp = File(cacheDir, fileName)
            if(tmp.exists()) {
                tmp.delete()
            }
            Log.i("Venera", "copy file (${fileName}) to ${tmp.absolutePath}")
            Thread {
                try {
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(tmp).use { output ->
                            input.copyTo(output, bufferSize = DEFAULT_BUFFER_SIZE)
                            output.flush()
                        }
                    }
                    result.success(tmp.absolutePath)
                }
                catch (e: Exception) {
                    result.error("copy error", e.message, null)
                }
            }.start()
        }
    }
}

class VolumeListen {
    var onUp = fun() {}
    var onDown = fun() {}
    fun up() {
        onUp()
    }

    fun down() {
        onDown()
    }
}

