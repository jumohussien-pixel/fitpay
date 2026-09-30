package com.example.sweat_and_scroll_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.SystemClock
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import java.io.ByteArrayOutputStream
import kotlin.math.atan2
import kotlin.math.min

class MediaPipeSquatCounter(private val context: Context) {
    private var landmarker: PoseLandmarker? = null
    private var isDown = false
    private var lastRepAt = 0L
    private var lastFrameAt = 0L

    @Synchronized
    fun processFrame(nv21: ByteArray, width: Int, height: Int, rotationDegrees: Int): Boolean {
        val inputBitmap = decodeNv21(nv21, width, height) ?: return false
        val rotatedBitmap = rotate(inputBitmap, rotationDegrees)
        if (rotatedBitmap !== inputBitmap) inputBitmap.recycle()
        return try {
            val timestamp = maxOf(SystemClock.uptimeMillis(), lastFrameAt + 1)
            lastFrameAt = timestamp
            val result = getLandmarker().detectForVideo(BitmapImageBuilder(rotatedBitmap).build(), timestamp)
            val pose = result.landmarks().firstOrNull() ?: return false
            updateSquatState(pose)
        } finally {
            rotatedBitmap.recycle()
        }
    }

    @Synchronized
    fun reset() {
        isDown = false
        lastRepAt = 0L
        lastFrameAt = 0L
    }

    @Synchronized
    fun close() {
        landmarker?.close()
        landmarker = null
    }

    private fun getLandmarker(): PoseLandmarker {
        return landmarker ?: PoseLandmarker.createFromOptions(
            context,
            PoseLandmarker.PoseLandmarkerOptions.builder()
                .setBaseOptions(
                    BaseOptions.builder()
                        .setModelAssetPath(MODEL_ASSET)
                        .build(),
                )
                .setRunningMode(RunningMode.VIDEO)
                .setNumPoses(1)
                .build(),
        ).also { landmarker = it }
    }

    private fun decodeNv21(bytes: ByteArray, width: Int, height: Int): Bitmap? {
        val output = ByteArrayOutputStream()
        val image = YuvImage(bytes, ImageFormat.NV21, width, height, null)
        if (!image.compressToJpeg(Rect(0, 0, width, height), JPEG_QUALITY, output)) return null
        return BitmapFactory.decodeByteArray(output.toByteArray(), 0, output.size())
    }

    private fun rotate(bitmap: Bitmap, degrees: Int): Bitmap {
        if (degrees % 360 == 0) return bitmap
        val matrix = Matrix().apply { postRotate(degrees.toFloat()) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    private fun updateSquatState(landmarks: List<com.google.mediapipe.tasks.components.containers.NormalizedLandmark>): Boolean {
        if (landmarks.size <= RIGHT_ANKLE_INDEX) return false
        val leftScore = min(
            min(landmarks[LEFT_HIP_INDEX].visibility().orElse(0f), landmarks[LEFT_KNEE_INDEX].visibility().orElse(0f)),
            landmarks[LEFT_ANKLE_INDEX].visibility().orElse(0f),
        )
        val rightScore = min(
            min(landmarks[RIGHT_HIP_INDEX].visibility().orElse(0f), landmarks[RIGHT_KNEE_INDEX].visibility().orElse(0f)),
            landmarks[RIGHT_ANKLE_INDEX].visibility().orElse(0f),
        )
        val indices = if (leftScore >= rightScore) {
            intArrayOf(LEFT_HIP_INDEX, LEFT_KNEE_INDEX, LEFT_ANKLE_INDEX)
        } else {
            intArrayOf(RIGHT_HIP_INDEX, RIGHT_KNEE_INDEX, RIGHT_ANKLE_INDEX)
        }
        if (maxOf(leftScore, rightScore) < MIN_VISIBILITY) return false

        val hip = landmarks[indices[0]]
        val knee = landmarks[indices[1]]
        val ankle = landmarks[indices[2]]
        val radians = atan2(ankle.y() - knee.y(), ankle.x() - knee.x()) -
            atan2(hip.y() - knee.y(), hip.x() - knee.x())
        var angle = kotlin.math.abs(radians * 180.0 / Math.PI)
        if (angle > 180.0) angle = 360.0 - angle

        if (angle < DOWN_ANGLE_DEGREES) isDown = true
        if (angle > UP_ANGLE_DEGREES && isDown) {
            isDown = false
            val now = SystemClock.elapsedRealtime()
            if (now - lastRepAt >= MIN_REP_INTERVAL_MS) {
                lastRepAt = now
                return true
            }
        }
        return false
    }

    companion object {
        private const val MODEL_ASSET = "pose_landmarker_lite.task"
        private const val JPEG_QUALITY = 80
        private const val LEFT_HIP_INDEX = 23
        private const val LEFT_KNEE_INDEX = 25
        private const val LEFT_ANKLE_INDEX = 27
        private const val RIGHT_HIP_INDEX = 24
        private const val RIGHT_KNEE_INDEX = 26
        private const val RIGHT_ANKLE_INDEX = 28
        private const val MIN_VISIBILITY = 0.55f
        private const val DOWN_ANGLE_DEGREES = 100.0
        private const val UP_ANGLE_DEGREES = 160.0
        private const val MIN_REP_INTERVAL_MS = 500L
    }
}