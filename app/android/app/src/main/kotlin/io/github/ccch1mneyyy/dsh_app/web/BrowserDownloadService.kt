package io.github.ccch1mneyyy.dsh_app.web

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.IBinder
import io.github.ccch1mneyyy.dsh_app.MainActivity

/** Keeps confirmed streaming work alive while the browser/chat route changes. */
class BrowserDownloadService : Service() {
    private lateinit var downloads: BrowserDownloads
    override fun onCreate() {
        super.onCreate()
        downloads = BrowserDownloads.get(this)
        val chinese = resources.configuration.locales[0].language == "zh"
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(CHANNEL,
            if (chinese) "浏览器下载" else "Browser downloads", NotificationManager.IMPORTANCE_LOW))
        startForeground(ID, notification())
        downloads.onServiceChanged = { update() }
    }
    private fun notification(): Notification {
        val chinese = resources.configuration.locales[0].language == "zh"
        val open = PendingIntent.getActivity(this, ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(if (chinese) "浏览器下载" else "Browser downloads")
            .setContentText(if (chinese) "${downloads.activeCount()} 个下载进行中 · 可在浏览器的下载页管理" else "${downloads.activeCount()} active · Manage in browser downloads")
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).build()
    }
    private fun update() {
        if (downloads.activeCount() == 0) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
        else getSystemService(NotificationManager::class.java).notify(ID, notification())
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int { update(); return START_NOT_STICKY }
    override fun onDestroy() { downloads.onServiceChanged = null; super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null
    companion object { private const val CHANNEL = "browser_downloads"; private const val ID = 6842 }
}
