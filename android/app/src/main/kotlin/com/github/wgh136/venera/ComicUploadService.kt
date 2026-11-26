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
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat

/**
 * 漫画备份上传期间的前台服务。
 *
 * 和 [ComicDownloadService] 是同一套思路，但**必须独立一个 Service**：前台
 * 通知是按 Service 实例挂的，如果复用下载那个，上传一开始就会把下载的通知
 * 顶掉，谁先结束谁把对方的进度条一起摘了。
 *
 * 收字节的还是 Dart 侧（分片、秒传、重试都在那儿），这里只负责：
 *  1. 把进程提到前台优先级，切到桌面、锁屏后续传不会被系统冻结；
 *  2. 持一把 PARTIAL_WAKE_LOCK，锁屏后定时器和网络回调不被挂起；
 *  3. 通知栏挂一条上传进度。
 *
 * 划掉最近任务 = 关 App，服务随任务结束（manifest 的 stopWithTask）。
 */
class ComicUploadService : Service() {

    companion object {
        private const val TAG = "ComicUpload"

        private const val CHANNEL_ID = "comic_upload"

        private const val NOTIFICATION_ID = 0x4D46

        /** 完成通知单独一个 id：服务销毁时会按 NOTIFICATION_ID 清前台通知，
         *  同 id 的话刚发的「上传完成」会被一起摘掉。 */
        private const val DONE_NOTIFICATION_ID = 0x4D47

        private const val ACTION_START =
            "com.github.wgh136.venera.action.START_COMIC_UPLOAD"

        private const val EXTRA_TITLE = "title"

        private const val EXTRA_TEXT = "text"

        private const val EXTRA_PROGRESS = "progress"

        fun start(context: Context, title: String, text: String, progress: Int = -1): Boolean {
            return try {
                val intent = Intent(context, ComicUploadService::class.java).apply {
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
                true
            } catch (e: Exception) {
                // 后台启动受限（Android 12+）时不要连累上传本身
                Log.e(TAG, "Failed to start service", e)
                false
            }
        }

        fun update(context: Context, title: String, text: String, progress: Int) {
            try {
                ensureChannel(context)
                NotificationManagerCompat.from(context)
                    .notify(NOTIFICATION_ID, build(context, title, text, progress))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to update notification", e)
            }
        }

        /**
         * 没有字节在传时把锁放掉：上传可能在等网络重试，一直攥着锁会白耗电。
         */
        fun setWakeLock(hold: Boolean) {
            instance?.setWakeLockWanted(hold)
        }

        /**
         * 后台上传完成后留一条可点掉的通知。
         *
         * 前台服务的通知是 ongoing 的、服务一停就消失；用户切出去干别的，
         * 回来只看到「什么都没了」，不知道传完没有。这条就是收尾用的。
         */
        fun notifyDone(context: Context, title: String, text: String) {
            try {
                ensureChannel(context)
                val contentIntent = PendingIntent.getActivity(
                    context,
                    0,
                    Intent(context, MainActivity::class.java).apply {
                        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP
                    },
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
                val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setContentIntent(contentIntent)
                    .setOngoing(false)
                    .setAutoCancel(true)
                    .setShowWhen(true)
                    .setOnlyAlertOnce(true)
                    .setPriority(NotificationCompat.PRIORITY_LOW)
                    .build()
                NotificationManagerCompat.from(context)
                    .notify(DONE_NOTIFICATION_ID, notification)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to post completion notification", e)
            }
        }

        @Volatile
        private var instance: ComicUploadService? = null

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, ComicUploadService::class.java))
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
                "Comic upload",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Progress of comic uploads to cloud storage"
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
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(contentIntent)
                .setOngoing(true)
                .setSilent(true)
                .setShowWhen(false)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setForegroundServiceBehavior(
                    NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE
                )
            }
            if (progress < 0) {
                builder.setProgress(0, 0, true)
            } else {
                builder.setProgress(100, progress.coerceIn(0, 100), false)
            }
            return builder.build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    @Volatile
    private var wakeLockWanted = true

    private val handler = Handler(Looper.getMainLooper())

    private fun setWakeLockWanted(hold: Boolean) {
        if (hold == wakeLockWanted) return
        wakeLockWanted = hold
        if (hold) {
            acquireWakeLock()
        } else {
            releaseWakeLock()
        }
    }

    private val renewRunnable = object : Runnable {
        override fun run() {
            renewWakeLock()
            handler.postDelayed(this, 25 * 60 * 1000L)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        acquireWakeLock()
        handler.postDelayed(renewRunnable, 25 * 60 * 1000L)
    }

    private fun acquireWakeLock() {
        try {
            if (!wakeLockWanted) return
            if (wakeLock?.isHeld == true) return
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "mancomic:upload"
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

    private fun renewWakeLock() {
        releaseWakeLock()
        acquireWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val title = intent.getStringExtra(EXTRA_TITLE) ?: "Uploading"
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
            renewWakeLock()
            handler.removeCallbacks(renewRunnable)
            handler.postDelayed(renewRunnable, 25 * 60 * 1000L)
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed", e)
            stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        handler.removeCallbacks(renewRunnable)
        releaseWakeLock()
        try {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        } catch (e: Exception) {
            Log.e(TAG, "stopForeground failed", e)
        }
        super.onDestroy()
    }

    /**
     * Android 15 的 dataSync 前台服务有累计时长上限，到点必须主动停。
     * 进度在 Dart 侧，重新回到应用点一下会继续。
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "Foreground service hit its time limit, stop (startId=$startId)")
        stopSelf()
    }
}
