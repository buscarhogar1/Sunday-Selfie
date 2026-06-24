package com.example.sunday_selfie

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.abs

class MainActivity : FlutterActivity() {
    private val methodChannelName = "sunday_selfie/foreground_notifications"
    private val mediaSaverChannelName = "sunday_selfie/media_saver"
    private val extraForegroundNotification = "foreground_notification"
    private val extraPayload = "payload"
    private var methodChannel: MethodChannel? = null
    private var mediaSaverChannel: MethodChannel? = null
    private var pendingLaunchPayload: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            methodChannelName
        )
        mediaSaverChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            mediaSaverChannelName
        )

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error(
                            "invalid-arguments",
                            "Missing notification arguments",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    showForegroundNotification(args)
                    result.success(null)
                }
                "getLaunchPayload" -> {
                    result.success(consumePendingLaunchPayload())
                }
                else -> result.notImplemented()
            }
        }

        mediaSaverChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveImagesToGallery" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error(
                            "invalid-arguments",
                            "Missing media saver arguments",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    Thread {
                        try {
                            val savedCount = saveImagesToGallery(args)
                            runOnUiThread {
                                if (savedCount > 0) {
                                    result.success(savedCount)
                                } else {
                                    result.error(
                                        "no-files-saved",
                                        "No images were saved",
                                        null
                                    )
                                }
                            }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error(
                                    "save-failed",
                                    error.localizedMessage ?: "Could not save images",
                                    null
                                )
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        handleForegroundNotificationIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleForegroundNotificationIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        handleForegroundNotificationIntent(intent)
    }

    private fun showForegroundNotification(args: Map<*, *>) {
        if (!notificationsAllowed()) return

        val title = (args["title"] as? String)
            ?.takeIf { it.isNotBlank() }
            ?: applicationInfo.loadLabel(packageManager).toString()
        val body = (args["body"] as? String).orEmpty()
        val payload = (args["payload"] as? String).orEmpty()
        val messageId = (args["messageId"] as? String).orEmpty()
        val soundEnabled = args["soundEnabled"] as? Boolean ?: true
        val vibrationEnabled = args["vibrationEnabled"] as? Boolean ?: true
        val channelId = foregroundChannelId(soundEnabled, vibrationEnabled)

        ensureNotificationChannel(channelId, soundEnabled, vibrationEnabled)

        val notificationId = stableNotificationId(
            messageId.ifBlank { payload.ifBlank { System.currentTimeMillis().toString() } }
        )
        val pendingIntent = PendingIntent.getActivity(
            this,
            notificationId,
            Intent(this, MainActivity::class.java).apply {
                action = "$packageName.FOREGROUND_NOTIFICATION.$notificationId"
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(extraForegroundNotification, true)
                putExtra(extraPayload, payload)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            Notification.Builder(this)
        }

        val notification = builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setShowWhen(true)
            .setWhen(System.currentTimeMillis())
            .setCategory(Notification.CATEGORY_REMINDER)
            .setPriority(Notification.PRIORITY_HIGH)
            .apply {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                    var defaults = 0
                    if (soundEnabled) defaults = defaults or Notification.DEFAULT_SOUND
                    if (vibrationEnabled) defaults = defaults or Notification.DEFAULT_VIBRATE
                    setDefaults(defaults)
                    if (!vibrationEnabled) setVibrate(longArrayOf(0L))
                }
            }
            .build()

        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(notificationId, notification)
    }

    private fun ensureNotificationChannel(
        channelId: String,
        soundEnabled: Boolean,
        vibrationEnabled: Boolean,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            channelId,
            "Notificaciones",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Avisos mientras Sunday Selfie está abierta"
            enableVibration(vibrationEnabled)
            if (!soundEnabled) {
                setSound(null, null)
            }
        }

        notificationManager.createNotificationChannel(channel)
    }

    private fun notificationsAllowed(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun foregroundChannelId(
        soundEnabled: Boolean,
        vibrationEnabled: Boolean,
    ): String {
        return when {
            soundEnabled && vibrationEnabled -> "sunday_foreground"
            soundEnabled -> "sunday_foreground_sound"
            vibrationEnabled -> "sunday_foreground_vibration"
            else -> "sunday_foreground_silent"
        }
    }

    private fun handleForegroundNotificationIntent(intent: Intent?) {
        val payload = consumePayload(intent) ?: return
        pendingLaunchPayload = payload
        methodChannel?.invokeMethod("notificationTap", payload)
    }

    private fun consumePayload(intent: Intent?): String? {
        if (intent?.getBooleanExtra(extraForegroundNotification, false) != true) {
            return null
        }

        val payload = intent.getStringExtra(extraPayload)
        intent.removeExtra(extraForegroundNotification)
        intent.removeExtra(extraPayload)
        return payload
    }

    private fun consumePendingLaunchPayload(): String? {
        val payload = pendingLaunchPayload
        pendingLaunchPayload = null
        return payload
    }

    private fun stableNotificationId(value: String): Int {
        val hash = value.hashCode()
        return if (hash == Int.MIN_VALUE) 0 else abs(hash)
    }

    private fun saveImagesToGallery(args: Map<*, *>): Int {
        val files = args["files"] as? List<*> ?: return 0
        var savedCount = 0

        for (entry in files) {
            val fileData = entry as? Map<*, *> ?: continue
            val path = (fileData["path"] as? String)?.takeIf { it.isNotBlank() }
                ?: continue
            val source = File(path)
            if (!source.exists()) continue

            val fileName = (fileData["name"] as? String)
                ?.takeIf { it.isNotBlank() }
                ?: source.name
            val mimeType = (fileData["mimeType"] as? String)
                ?.takeIf { it.isNotBlank() }
                ?: "image/jpeg"

            if (saveImageToGallery(source, fileName, mimeType)) {
                savedCount += 1
            }
        }

        return savedCount
    }

    private fun saveImageToGallery(
        source: File,
        fileName: String,
        mimeType: String,
    ): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveImageWithMediaStore(source, fileName, mimeType)
        } else {
            saveImageToPublicPictures(source, fileName, mimeType)
        }
    }

    private fun saveImageWithMediaStore(
        source: File,
        fileName: String,
        mimeType: String,
    ): Boolean {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
            put(MediaStore.Images.Media.MIME_TYPE, mimeType)
            put(
                MediaStore.Images.Media.RELATIVE_PATH,
                "${Environment.DIRECTORY_PICTURES}/Sunday Selfie"
            )
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }

        val resolver = contentResolver
        val uri = resolver.insert(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            values
        ) ?: return false

        var saved = false
        try {
            val outputStream = resolver.openOutputStream(uri) ?: return false
            outputStream.use { output ->
                source.inputStream().use { input ->
                    input.copyTo(output)
                }
            }

            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            saved = true
            return true
        } finally {
            if (!saved) {
                resolver.delete(uri, null, null)
            }
        }
    }

    private fun saveImageToPublicPictures(
        source: File,
        fileName: String,
        mimeType: String,
    ): Boolean {
        val picturesDirectory = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_PICTURES
        )
        val sundayDirectory = File(picturesDirectory, "Sunday Selfie").apply {
            mkdirs()
        }
        val destination = uniqueDestinationFile(sundayDirectory, fileName)

        source.inputStream().use { input ->
            destination.outputStream().use { output ->
                input.copyTo(output)
            }
        }

        MediaScannerConnection.scanFile(
            this,
            arrayOf(destination.absolutePath),
            arrayOf(mimeType),
            null
        )

        return true
    }

    private fun uniqueDestinationFile(directory: File, fileName: String): File {
        val extensionIndex = fileName.lastIndexOf('.')
        val baseName = if (extensionIndex > 0) {
            fileName.substring(0, extensionIndex)
        } else {
            fileName
        }
        val extension = if (extensionIndex > 0) {
            fileName.substring(extensionIndex)
        } else {
            ""
        }

        var destination = File(directory, fileName)
        var copyIndex = 1
        while (destination.exists()) {
            destination = File(directory, "${baseName}_$copyIndex$extension")
            copyIndex += 1
        }

        return destination
    }
}
