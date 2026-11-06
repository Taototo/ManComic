package com.github.wgh136.venera

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.util.Log
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

