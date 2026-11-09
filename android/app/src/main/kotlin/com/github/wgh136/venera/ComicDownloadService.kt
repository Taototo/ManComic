package com.github.wgh136.venera

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat

/**
 * 漫画下载期间的前台服务。
 *
 * 收字节的还是 Dart 侧那套（断点续传、校验、重试都在那儿），这个服务只做
 * 三件事：
 *  1. 把进程提到前台优先级。不加的话回到桌面一会儿就可能被系统冻结、回收，
 *     下载停在那儿，用户回来一看「刚才不是还在下吗」。
 *  2. 持一把 PARTIAL_WAKE_LOCK。通知栏有前台服务不等于 CPU 不睡，锁屏后
 *     定时器和网络回调会被系统挂起，下载就假死。下载结束/服务销毁时释放。
 *  3. 在通知栏挂一条合计进度。
 *
 * 生命周期跟用户的理解一致：从最近任务里划掉应用 = 关掉 App，服务随任务
 * 结束（manifest 里的 stopWithTask），没下完的部分留着下次续传。
 */
class ComicDownloadService : Service() {

    companion object {
        private const val TAG = "ComicDownload"

        private const val CHANNEL_ID = "comic_download"

        private const val NOTIFICATION_ID = 0x4D44

        private const val ACTION_START =
            "com.github.wgh136.venera.action.START_COMIC_DOWNLOAD"

        private const val EXTRA_TITLE = "title"

        private const val EXTRA_TEXT = "text"

        private const val EXTRA_PROGRESS = "progress"

        /** 启动前台服务并立刻显示通知（进度未知时用 -1）。 */
        fun start(context: Context, title: String, text: String, progress: Int = -1) {
            try {
                val intent = Intent(context, ComicDownloadService::class.java).apply {
                    action = ACTION_START
                    putExtra(EXTRA_TITLE, title)
                    putExtra(EXTRA_TEXT, text)
                    putExtra(EXTRA_PROGRESS, progress)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // 后台启动受限（Android 12+）时不要连累下载本身
                Log.e(TAG, "Failed to start service", e)
            }
        }

        /**
         * 刷新进度。
         *
         * 直接走 NotificationManager 而不是再发一次 startService：下载每秒都在
         * 更新，反复跑 onStartCommand 没必要，通知按 id 覆盖即可。
         */
        fun update(context: Context, title: String, text: String, progress: Int) {
            try {
                ensureChannel(context)
                NotificationManagerCompat.from(context)
                    .notify(NOTIFICATION_ID, build(context, title, text, progress))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to update notification", e)
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, ComicDownloadService::class.java))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to stop service", e)
            }
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Comic download",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Progress of comic downloads"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
            manager.createNotificationChannel(channel)
        }

        private fun build(
            context: Context,
            title: String,
            text: String,
            progress: Int
        ): Notification {
            val contentIntent = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP
                },
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(contentIntent)
                .setOngoing(true)
                .setSilent(true)
                .setShowWhen(false)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
            if (progress < 0) {
                builder.setProgress(0, 0, true)
            } else {
                builder.setProgress(100, progress.coerceIn(0, 100), false)
            }
            return builder.build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        acquireWakeLock()
    }

    /**
     * 拿一把不计数（reference counted = false）的 partial wakelock。
     *
     * 超时只是兜底：正常路径由 stopSelf/onDestroy 释放，万一 Dart 侧没机会
     * 收尾（进程被强杀），锁也随进程消失，不会一直耗电。
     */
    private fun acquireWakeLock() {
        try {
            if (wakeLock?.isHeld == true) return
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "mancomic:download"
            ).apply {
                setReferenceCounted(false)
                acquire(2 * 60 * 60 * 1000L)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire wake lock", e)
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to release wake lock", e)
        }
        wakeLock = null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val title = intent.getStringExtra(EXTRA_TITLE) ?: "Downloading"
        val text = intent.getStringExtra(EXTRA_TEXT) ?: ""
        val progress = intent.getIntExtra(EXTRA_PROGRESS, -1)
        ensureChannel(this)
        try {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            }
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                build(this, title, text, progress),
                type
            )
            acquireWakeLock()
        } catch (e: Exception) {
            // 拿不到前台资格（权限被撤、后台启动）就别硬撑了
            Log.e(TAG, "startForeground failed", e)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        try {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        } catch (e: Exception) {
            Log.e(TAG, "stopForeground failed", e)
        }
        super.onDestroy()
    }
}
