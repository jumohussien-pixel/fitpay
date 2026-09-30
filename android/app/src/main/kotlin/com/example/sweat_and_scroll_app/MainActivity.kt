package com.example.sweat_and_scroll_app

import android.Manifest
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {
    private val methodChannelName = "com.example.sweat_and_scroll_app/overlay"
    private val eventChannelName = "com.example.sweat_and_scroll_app/session_events"
    private val poseChannelName = "com.example.sweat_and_scroll_app/pose"
    private lateinit var squatCounter: MediaPipeSquatCounter

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        squatCounter = MediaPipeSquatCounter(this)
        val imageTaskQueue = flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkPermissions" -> result.success(permissionState())
                    "requestOverlayPermission" -> {
                        openOverlaySettings()
                        result.success(true)
                    }
                    "requestUsageStatsPermission" -> {
                        startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                        result.success(true)
                    }
                    "requestActivityRecognitionPermission" -> {
                        requestActivityRecognitionPermission()
                        result.success(true)
                    }
                    "requestNotificationPermission" -> {
                        requestNotificationPermission()
                        result.success(true)
                    }
                    "startSession" -> startSession(call.arguments as? Map<*, *>, result)
                    "stopSession" -> {
                        stopSession()
                        result.success(true)
                    }
                    "getSessionState" -> result.success(ForegroundTrackingService.sessionState())
                    "recordSquat" -> {
                        val serviceIntent = Intent(this, ForegroundTrackingService::class.java)
                            .setAction(ForegroundTrackingService.ACTION_RECORD_SQUAT)
                        startService(serviceIntent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            poseChannelName,
            StandardMethodCodec.INSTANCE,
            imageTaskQueue,
        ).setMethodCallHandler { call, result ->
            if (call.method == "processSquatFrame") {
                processSquatFrame(call.arguments as? Map<*, *>, result)
            } else {
                result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    FitPayEventBus.sink = events
                    if (FitPayEventBus.openWorkoutPending || intent.getBooleanExtra(ForegroundTrackingService.EXTRA_OPEN_WORKOUT, false)) {
                        FitPayEventBus.openWorkoutPending = false
                        intent.removeExtra(ForegroundTrackingService.EXTRA_OPEN_WORKOUT)
                        FitPayEventBus.requestOpenWorkout()
                    }
                }

                override fun onCancel(arguments: Any?) {
                    FitPayEventBus.sink = null
                }
            })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra(ForegroundTrackingService.EXTRA_OPEN_WORKOUT, false)) {
            intent.removeExtra(ForegroundTrackingService.EXTRA_OPEN_WORKOUT)
            FitPayEventBus.requestOpenWorkout()
        }
    }

    override fun onDestroy() {
        if (::squatCounter.isInitialized) squatCounter.close()
        super.onDestroy()
    }

    private fun startSession(arguments: Map<*, *>?, result: MethodChannel.Result) {
        if (!Settings.canDrawOverlays(this)) {
            result.error("overlay_permission", "Display over other apps permission is required.", null)
            return
        }
        if (!hasUsageStatsPermission()) {
            result.error("usage_permission", "Usage Access permission is required.", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACTIVITY_RECOGNITION) != PackageManager.PERMISSION_GRANTED
        ) {
            result.error("activity_permission", "Activity recognition permission is required.", null)
            return
        }

        val intent = Intent(this, ForegroundTrackingService::class.java)
            .setAction(ForegroundTrackingService.ACTION_START)
            .putExtra(ForegroundTrackingService.EXTRA_MODE, arguments?.get("mode") as? String ?: "steps")
            .putExtra(ForegroundTrackingService.EXTRA_GOAL, (arguments?.get("goal") as? Number)?.toInt() ?: 100)
            .putStringArrayListExtra(
                ForegroundTrackingService.EXTRA_PACKAGES,
                ArrayList((arguments?.get("packages") as? List<*>)?.filterIsInstance<String>() ?: emptyList()),
            )
        if (arguments?.get("mode") == "squats") squatCounter.reset()
        ContextCompat.startForegroundService(this, intent)
        result.success(true)
    }

    private fun processSquatFrame(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val bytes = arguments?.get("bytes") as? ByteArray
        val width = (arguments?.get("width") as? Number)?.toInt() ?: 0
        val height = (arguments?.get("height") as? Number)?.toInt() ?: 0
        val rotation = (arguments?.get("rotationDegrees") as? Number)?.toInt() ?: 0
        if (bytes == null || width <= 0 || height <= 0) {
            result.success(false)
            return
        }
        try {
            val repCompleted = squatCounter.processFrame(bytes, width, height, rotation)
            if (repCompleted && ForegroundTrackingService.sessionState()["active"] == true) {
                startService(
                    Intent(this, ForegroundTrackingService::class.java)
                        .setAction(ForegroundTrackingService.ACTION_RECORD_SQUAT),
                )
            }
            result.success(repCompleted)
        } catch (exception: Exception) {
            result.error("pose_processing", exception.message, null)
        }
    }

    private fun stopSession() {
        stopService(Intent(this, ForegroundTrackingService::class.java))
    }

    private fun requestActivityRecognitionPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACTIVITY_RECOGNITION) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.ACTIVITY_RECOGNITION),
                ACTIVITY_RECOGNITION_REQUEST,
            )
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_REQUEST,
            )
        }
    }

    private fun openOverlaySettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")),
            )
        }
    }

    private fun permissionState(): Map<String, Boolean> = mapOf(
        "overlay" to Settings.canDrawOverlays(this),
        "usageStats" to hasUsageStatsPermission(),
        "activityRecognition" to (
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                ContextCompat.checkSelfPermission(this, Manifest.permission.ACTIVITY_RECOGNITION) == PackageManager.PERMISSION_GRANTED
            ),
    )

    private fun hasUsageStatsPermission(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName)
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    companion object {
        private const val ACTIVITY_RECOGNITION_REQUEST = 701
        private const val NOTIFICATION_REQUEST = 702
    }
}

object FitPayEventBus {
    @Volatile
    var sink: EventChannel.EventSink? = null
    @Volatile
    var openWorkoutPending = false

    fun requestOpenWorkout() {
        if (sink == null) {
            openWorkoutPending = true
        } else {
            emit(mapOf("type" to "openWorkout"))
        }
    }

    fun emit(event: Map<String, Any>) {
        sink?.let { eventSink ->
            android.os.Handler(android.os.Looper.getMainLooper()).post { eventSink.success(event) }
        }
    }
}