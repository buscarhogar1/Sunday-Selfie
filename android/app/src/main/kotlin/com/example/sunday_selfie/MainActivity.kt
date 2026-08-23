package app.sundayselfie

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
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs

class MainActivity : FlutterActivity() {
    private val methodChannelName = "sunday_selfie/foreground_notifications"
    private val mediaSaverChannelName = "sunday_selfie/media_saver"
    private val volumeButtonsChannelName = "sunday_selfie/volume_buttons"
    private val deepLinksChannelName = "sunday_selfie/deep_links"
    private val deepLinksEventChannelName = "sunday_selfie/deep_links/events"
    private val extraForegroundNotification = "foreground_notification"
    private val extraPayload = "payload"
    private var methodChannel: MethodChannel? = null
    private var mediaSaverChannel: MethodChannel? = null
    private var volumeButtonsChannel: MethodChannel? = null
    private var deepLinksChannel: MethodChannel? = null
    private var deepLinksEventChannel: EventChannel? = null
    private var deepLinksEventSink: EventChannel.EventSink? = null
    private var pendingLaunchPayload: String? = null
    private var initialDeepLink: String? = null
    private var latestDeepLink: String? = null
    private var volumeButtonCaptureEnabled = false

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
        volumeButtonsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            volumeButtonsChannelName
        )
        deepLinksChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            deepLinksChannelName
        )
        deepLinksEventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            deepLinksEventChannelName
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

        volumeButtonsChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setCaptureEnabled" -> {
                    val args = call.arguments as? Map<*, *>
                    volumeButtonCaptureEnabled = args?.get("enabled") as? Boolean ?: false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        deepLinksChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialLink" -> result.success(initialDeepLink ?: latestDeepLink)
                else -> result.notImplemented()
            }
        }
        deepLinksEventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                deepLinksEventSink = events
                latestDeepLink?.let { events?.success(it) }
            }

            override fun onCancel(arguments: Any?) {
                deepLinksEventSink = null
            }
        })

        handleForegroundNotificationIntent(intent)
        handleDeepLinkIntent(intent)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (volumeButtonCaptureEnabled && isVolumeKey(event.keyCode)) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                volumeButtonsChannel?.invokeMethod("volumeButtonPressed", null)
            }
            return true
        }

        return super.dispatchKeyEvent(event)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleForegroundNotificationIntent(intent)
        handleDeepLinkIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        handleForegroundNotificationIntent(intent)
        handleDeepLinkIntent(intent)
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

    private fun handleDeepLinkIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        if (intent.action != Intent.ACTION_VIEW || !isSundaySelfieDeepLink(uri)) {
            return
        }

        val value = uri.toString()
        if (initialDeepLink == null) {
            initialDeepLink = value
        }
        if (latestDeepLink == value) return

        latestDeepLink = value
        deepLinksEventSink?.success(value)
    }

    private fun isSundaySelfieDeepLink(uri: Uri): Boolean {
        if (uri.scheme?.lowercase() != "https") return false
        val host = uri.host?.lowercase() ?: return false
        if (host != "sundayselfie.app" && host != "www.sundayselfie.app") {
            return false
        }

        val firstPathSegment = uri.pathSegments.firstOrNull()?.lowercase()
        return firstPathSegment == "j" ||
            firstPathSegment == "join" ||
            firstPathSegment == "invite"
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

    private fun isVolumeKey(keyCode: Int): Boolean {
        return keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
            keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
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
                ?.let { File(it).name }
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
        val nowMillis = System.currentTimeMillis()
        val nowSeconds = nowMillis / 1000
        val relativePath = "${Environment.DIRECTORY_PICTURES}/Sunday Selfie"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
            put(MediaStore.Images.Media.MIME_TYPE, mimeType)
            put(MediaStore.Images.Media.RELATIVE_PATH, relativePath)
            put(MediaStore.Images.Media.DATE_ADDED, nowSeconds)
            put(MediaStore.Images.Media.DATE_MODIFIED, nowSeconds)
            put(MediaStore.Images.Media.DATE_TAKEN, nowMillis)
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
            values.put(MediaStore.Images.Media.DATE_MODIFIED, nowSeconds)
            resolver.update(uri, values, null, null)
            scanSavedImage(
                File(
                    Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_PICTURES
                    ),
                    "Sunday Selfie/$fileName"
                ).absolutePath,
                mimeType
            )
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

        scanSavedImage(destination.absolutePath, mimeType)

        return true
    }

    private fun scanSavedImage(path: String, mimeType: String) {
        val latch = CountDownLatch(1)
        MediaScannerConnection.scanFile(
            this,
            arrayOf(path),
            arrayOf(mimeType)
        ) { _, _ ->
            latch.countDown()
        }

        try {
            latch.await(2, TimeUnit.SECONDS)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
        }
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
