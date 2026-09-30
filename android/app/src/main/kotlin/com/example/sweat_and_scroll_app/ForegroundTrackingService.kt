package com.example.sweat_and_scroll_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat

class ForegroundTrackingService : Service(), SensorEventListener {
    private val handler = Handler(Looper.getMainLooper())
    private val blockedPackages = mutableSetOf<String>()
    private var mode = MODE_STEPS
    private var goal = DEFAULT_STEP_GOAL
    private var currentCount = 0
    private var activePackage: String? = null
    private var baselineSteps: Float? = null
    private var overlayView: FrameLayout? = null
    private var overlayProgressText: TextView? = null
    private var windowManager: WindowManager? = null
    private var sessionActive = false
    private val sensorManager by lazy { getSystemService(Context.SENSOR_SERVICE) as SensorManager }

    private val usagePoller = object : Runnable {
        override fun run() {
            if (!sessionActive) return
            updateForegroundPackage()
            updateOverlay()
            handler.postDelayed(this, USAGE_POLL_INTERVAL_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startSession(intent)
            ACTION_RECORD_SQUAT -> recordSquat()
            ACTION_STOP -> finishSession(completed = false)
        }
        return START_NOT_STICKY
    }

    private fun startSession(intent: Intent) {
        mode = intent.getStringExtra(EXTRA_MODE) ?: MODE_STEPS
        goal = intent.getIntExtra(EXTRA_GOAL, DEFAULT_STEP_GOAL).coerceAtLeast(1)
        blockedPackages.clear()
        blockedPackages.addAll(intent.getStringArrayListExtra(EXTRA_PACKAGES).orEmpty())
        currentCount = 0
        baselineSteps = null
        sessionActive = true
        active = true
        activeCount = 0
        activeGoal = goal
        activeMode = mode

        startForeground(NOTIFICATION_ID, buildNotification())
        if (mode != MODE_SQUATS) {
            val stepSensor = sensorManager.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)
            if (stepSensor == null) {
                FitPayEventBus.emit(mapOf("type" to "sensorUnavailable"))
            } else {
                sensorManager.registerListener(this, stepSensor, SensorManager.SENSOR_DELAY_NORMAL)
            }
        }
        handler.removeCallbacks(usagePoller)
        handler.post(usagePoller)
        emitState()
    }

    private fun buildNotification(): Notification {
        createNotificationChannel()
        val stopIntent = Intent(this, ForegroundTrackingService::class.java).setAction(ACTION_STOP)
        val stopPendingIntent = PendingIntent.getService(
            this,
            STOP_REQUEST_CODE,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentTitle("FitPay")
            .setContentText("FitPay يعمل بالخلفية لتتبع نشاطك")
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .addAction(android.R.drawable.ic_media_pause, "إيقاف الجلسة", stopPendingIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "FitPay session tracking",
                NotificationManager.IMPORTANCE_LOW,
            )
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (!sessionActive || mode == MODE_SQUATS || event?.sensor?.type != Sensor.TYPE_STEP_COUNTER) return
        val totalSinceBoot = event.values.firstOrNull() ?: return
        if (baselineSteps == null) {
            baselineSteps = totalSinceBoot
            return
        }
        val nextCount = (totalSinceBoot - (baselineSteps ?: totalSinceBoot)).toInt().coerceAtLeast(0)
        if (nextCount > currentCount) {
            currentCount = nextCount
            activeCount = currentCount
            emitState()
            if (currentCount >= goal) finishSession(completed = true)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun recordSquat() {
        if (!sessionActive || mode == MODE_STEPS) return
        currentCount += 1
        activeCount = currentCount
        emitState()
        if (currentCount >= goal) finishSession(completed = true)
    }

    private fun updateForegroundPackage() {
        val usageStats = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now = System.currentTimeMillis()
        val events = usageStats.queryEvents(now - USAGE_LOOKBACK_MS, now)
        val event = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            if (event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND ||
                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && event.eventType == UsageEvents.Event.ACTIVITY_RESUMED)
            ) {
                activePackage = event.packageName
            }
        }
    }

    private fun updateOverlay() {
        if (activePackage != null && activePackage != packageName && activePackage in blockedPackages) {
            if (overlayView == null) {
                showOverlay()
            } else {
                overlayProgressText?.text = "$currentCount / $goal"
            }
        } else {
            removeOverlay()
        }
    }

    private fun showOverlay() {
        if (overlayView != null) return
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        val root = FrameLayout(this).apply { setBackgroundColor(Color.rgb(10, 14, 20)) }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
        }
        val title = TextView(this).apply {
            text = "أكمل هدفك لفتح التطبيق"
            textSize = 28f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }
        val progress = TextView(this).apply {
            text = "$currentCount / $goal"
            textSize = 22f
            setTextColor(Color.rgb(0, 240, 255))
            gravity = Gravity.CENTER
            setPadding(0, 24, 0, 36)
        }
        overlayProgressText = progress
        val exerciseButton = Button(this).apply {
            text = "بدء التمرين لفتح التطبيق"
            setOnClickListener { openWorkout() }
        }
        val emergencyButton = Button(this).apply {
            text = "خروج طارئ"
            setOnClickListener { finishSession(completed = false) }
        }
        content.addView(title)
        content.addView(progress)
        content.addView(exerciseButton)
        content.addView(emergencyButton)
        root.addView(content, FrameLayout.LayoutParams(-1, -1))

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            type,
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.START }

        try {
            windowManager?.addView(root, params)
            overlayView = root
        } catch (_: SecurityException) {
            overlayProgressText = null
            FitPayEventBus.emit(mapOf("type" to "overlayPermissionMissing"))
        }
    }

    private fun openWorkout() {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_OPEN_WORKOUT, true)
        startActivity(intent)
    }

    private fun removeOverlay() {
        overlayView?.let { view ->
            try {
                windowManager?.removeView(view)
            } catch (_: IllegalArgumentException) {
            }
        }
        overlayView = null
        overlayProgressText = null
    }

    private fun emitState() {
        FitPayEventBus.emit(
            mapOf("type" to "sessionState", "active" to sessionActive, "mode" to mode, "count" to currentCount, "goal" to goal),
        )
        activeCount = currentCount
    }

    private fun finishSession(completed: Boolean) {
        if (!sessionActive) {
            stopSelf()
            return
        }
        sessionActive = false
        active = false
        sensorManager.unregisterListener(this)
        handler.removeCallbacks(usagePoller)
        removeOverlay()
        FitPayEventBus.emit(mapOf("type" to if (completed) "goalCompleted" else "sessionStopped", "count" to currentCount))
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        sessionActive = false
        active = false
        sensorManager.unregisterListener(this)
        handler.removeCallbacks(usagePoller)
        removeOverlay()
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "com.fitpay.session.START"
        const val ACTION_STOP = "com.fitpay.session.STOP"
        const val ACTION_RECORD_SQUAT = "com.fitpay.session.RECORD_SQUAT"
        const val EXTRA_MODE = "mode"
        const val EXTRA_GOAL = "goal"
        const val EXTRA_PACKAGES = "packages"
        const val EXTRA_OPEN_WORKOUT = "open_workout"
        private const val MODE_STEPS = "steps"
        private const val MODE_SQUATS = "squats"
        private const val DEFAULT_STEP_GOAL = 100
        private const val NOTIFICATION_CHANNEL_ID = "fitpay_activity_session"
        private const val NOTIFICATION_ID = 2401
        private const val STOP_REQUEST_CODE = 2402
        private const val USAGE_POLL_INTERVAL_MS = 600L
        private const val USAGE_LOOKBACK_MS = 3000L

        @Volatile private var active = false
        @Volatile private var activeMode = MODE_STEPS
        @Volatile private var activeGoal = DEFAULT_STEP_GOAL
        @Volatile private var activeCount = 0

        fun sessionState(): Map<String, Any> = mapOf(
            "active" to active,
            "mode" to activeMode,
            "goal" to activeGoal,
            "count" to activeCount,
        )
    }
}