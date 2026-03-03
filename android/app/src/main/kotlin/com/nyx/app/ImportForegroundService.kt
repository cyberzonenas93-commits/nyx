package com.nyx.app

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

class ImportForegroundService : Service() {
    private val CHANNEL_ID = "import_service_channel"
    private val NOTIFICATION_ID = 1
    
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "UPDATE_PROGRESS" -> {
                val current = intent.getIntExtra("current", 0)
                val total = intent.getIntExtra("total", 0)
                val status = intent.getStringExtra("status") ?: "Processing..."
                updateNotification(current, total, status)
            }
            else -> {
                val reason = intent?.getStringExtra("reason") ?: "Importing files"
                val notification = createNotification(0, 0, reason)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    // Android 14+ requires foreground service type
                    ServiceCompat.startForeground(
                        this,
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
            }
        }
        return START_STICKY // Restart if killed
    }
    
    override fun onBind(intent: Intent?): IBinder? = null
    
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Import Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows import progress"
                setShowBadge(false)
            }
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }
    
    private fun createNotification(current: Int, total: Int, status: String): Notification {
        val progress = if (total > 0) {
            (current * 100 / total).coerceIn(0, 100)
        } else {
            0
        }
        
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Importing to Vault")
            .setContentText(if (total > 0) "$status ($current/$total)" else status)
            .setSmallIcon(android.R.drawable.ic_menu_upload)
            .setProgress(100, progress, total == 0)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
    }
    
    private fun updateNotification(current: Int, total: Int, status: String) {
        val notification = createNotification(current, total, status)
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.notify(NOTIFICATION_ID, notification)
    }
    
    override fun onDestroy() {
        super.onDestroy()
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.cancel(NOTIFICATION_ID)
    }
}
