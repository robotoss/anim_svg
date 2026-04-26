package com.robotoss.thorvg_plus

import android.os.Handler
import android.os.SystemClock
import android.view.Surface
import io.flutter.view.TextureRegistry

/**
 * One Lottie animation, rendered into a Flutter `Texture(textureId)`.
 *
 * **Threading invariant**: every call into the JNI bridge across **all**
 * textures runs on the plugin's shared render handler. thorvg is initialized
 * with `TaskScheduler::threads() == 0`, which disables every internal
 * `ScopedLock` (see `tvgLock.h:38-42`); this leaves the global `LoaderMgr`
 * loader list and other shared structures unprotected. The previous
 * per-texture `HandlerThread` design crashed inside `canvas->update()` when
 * 8 animations loaded in parallel and raced on this state.
 *
 * Single shared thread costs us core-level parallelism, but the primary
 * goal — keeping the Flutter UI isolate idle during scroll — is preserved
 * either way.
 */
internal class ThorvgTexture private constructor(
    private val entry: TextureRegistry.SurfaceTextureEntry,
    private val handler: Handler,
    private val initialData: ByteArray,
    private var renderWidth: Int,
    private var renderHeight: Int,
    private val animate: Boolean,
    private val repeat: Boolean,
    private val reverse: Boolean,
    private val speed: Double,
) {

    val id: Long = entry.id()

    var totalFrame: Float = 0f
        private set
    var duration: Float = 0f
        private set
    var lottieWidth: Int = 0
        private set
    var lottieHeight: Int = 0
        private set

    private val surface: Surface

    /** Native pointer; 0 before init or after destroy. Touched only from [handler]. */
    private var nativeHandle: Long = 0L

    @Volatile private var disposed: Boolean = false
    @Volatile private var initialized: Boolean = false

    /** Animation state — touched only from [handler]. */
    private var playing: Boolean = false
    private var startTimeMs: Long = 0L
    private var lastFrameRendered: Float = Float.NaN
    private var nextRunTime: Long = 0L

    init {
        entry.surfaceTexture().setDefaultBufferSize(renderWidth, renderHeight)
        surface = Surface(entry.surfaceTexture())
    }

    fun play() {
        if (disposed) return
        handler.post {
            if (disposed || !initialized) return@post
            startPlayingOnHandler()
        }
    }

    fun pause() {
        if (disposed) return
        handler.post {
            playing = false
            handler.removeCallbacks(tickRunnable)
        }
    }

    fun seek(frame: Float) {
        if (disposed) return
        handler.post {
            if (disposed || !initialized) return@post
            playing = false
            handler.removeCallbacks(tickRunnable)
            renderFrame(frame, force = true)
        }
    }

    fun resize(w: Int, h: Int) {
        if (disposed || w <= 0 || h <= 0) return
        handler.post {
            if (disposed || !initialized) return@post
            if (w == renderWidth && h == renderHeight) return@post
            renderWidth = w
            renderHeight = h
            entry.surfaceTexture().setDefaultBufferSize(w, h)
            nativeResize(nativeHandle, w, h)
            val resumeFrame = if (lastFrameRendered.isNaN()) 0f else lastFrameRendered
            renderFrame(resumeFrame, force = true)
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        handler.post {
            handler.removeCallbacks(tickRunnable)
            try { surface.release() } catch (_: Throwable) {}
            try { entry.release() } catch (_: Throwable) {}
            if (nativeHandle != 0L) {
                nativeDestroy(nativeHandle)
                nativeHandle = 0L
            }
        }
    }

    // -------------------------------------------------------------------- //
    // Handler-thread-only methods                                          //
    // -------------------------------------------------------------------- //

    private fun initOnHandler() {
        nativeHandle = nativeCreate()
        if (nativeHandle == 0L) {
            throw IllegalStateException("nativeCreate returned 0")
        }
        if (!nativeLoad(nativeHandle, initialData, renderWidth, renderHeight)) {
            val err = nativeError(nativeHandle)
            nativeDestroy(nativeHandle)
            nativeHandle = 0L
            throw IllegalStateException("Lottie load failed: $err")
        }
        totalFrame = nativeTotalFrame(nativeHandle)
        duration = nativeDuration(nativeHandle)
        val sz = FloatArray(2)
        nativeSize(nativeHandle, sz)
        lottieWidth = sz[0].toInt()
        lottieHeight = sz[1].toInt()
        initialized = true

        renderFrame(0f, force = true)
        if (animate) startPlayingOnHandler()
    }

    private fun cleanupAfterFailedInitOnHandler() {
        try { surface.release() } catch (_: Throwable) {}
        try { entry.release() } catch (_: Throwable) {}
    }

    private fun startPlayingOnHandler() {
        playing = true
        startTimeMs = SystemClock.uptimeMillis()
        nextRunTime = startTimeMs + FRAME_INTERVAL_MS
        handler.removeCallbacks(tickRunnable)
        tickRunnable.run()
    }

    private val tickRunnable = object : Runnable {
        override fun run() {
            if (disposed || !playing || !initialized) return
            val now = SystemClock.uptimeMillis()
            val durSec = duration.toDouble()
            if (durSec <= 0.0 || totalFrame <= 0f) {
                renderFrame(0f, force = true)
                playing = false
                return
            }

            val elapsedSec = (now - startTimeMs) / 1000.0
            val rawFrame = elapsedSec / durSec * totalFrame.toDouble() * speed
            var current = if (reverse) totalFrame - rawFrame.toFloat() else rawFrame.toFloat()

            val ended = if (reverse) current <= 0f else current >= totalFrame
            if (ended) {
                if (repeat) {
                    startTimeMs = now
                    current = if (reverse) totalFrame else 0f
                } else {
                    renderFrame(if (reverse) 0f else totalFrame - 1f, force = true)
                    playing = false
                    return
                }
            }

            renderFrame(current, force = false)

            nextRunTime += FRAME_INTERVAL_MS
            if (nextRunTime <= now) nextRunTime = now + FRAME_INTERVAL_MS
            handler.postAtTime(this, nextRunTime)
        }
    }

    private fun renderFrame(frame: Float, force: Boolean) {
        if (disposed || nativeHandle == 0L) return
        val rounded = if (totalFrame >= 1f) Math.round(frame).toFloat() else frame
        if (!force && rounded == lastFrameRendered) return
        nativeRenderToSurface(nativeHandle, rounded, renderWidth, renderHeight, surface)
        lastFrameRendered = rounded
    }

    // -------------------------------------------------------------------- //
    // JNI                                                                  //
    // -------------------------------------------------------------------- //

    private external fun nativeCreate(): Long
    private external fun nativeDestroy(handle: Long)
    private external fun nativeLoad(handle: Long, data: ByteArray, w: Int, h: Int): Boolean
    private external fun nativeDuration(handle: Long): Float
    private external fun nativeTotalFrame(handle: Long): Float
    private external fun nativeSize(handle: Long, out: FloatArray)
    private external fun nativeResize(handle: Long, w: Int, h: Int)
    private external fun nativeFrame(handle: Long, no: Float): Boolean
    private external fun nativeError(handle: Long): String
    private external fun nativeRenderToSurface(
        handle: Long,
        frameNo: Float,
        w: Int,
        h: Int,
        surface: Surface,
    ): Boolean

    companion object {
        private const val FRAME_INTERVAL_MS = 16L  // ~60 FPS pacing

        /**
         * Asynchronously builds a [ThorvgTexture]. The texture borrows the
         * plugin's shared render handler; all per-instance native init runs
         * on it. The [callback] is invoked from that thread once init is
         * done (success or failure).
         */
        fun createAsync(
            registry: TextureRegistry,
            handler: Handler,
            data: ByteArray,
            width: Int,
            height: Int,
            animate: Boolean,
            repeat: Boolean,
            reverse: Boolean,
            speed: Double,
            callback: (Result<ThorvgTexture>) -> Unit,
        ) {
            val entry = registry.createSurfaceTexture()
            val tex = ThorvgTexture(
                entry = entry,
                handler = handler,
                initialData = data,
                renderWidth = width,
                renderHeight = height,
                animate = animate,
                repeat = repeat,
                reverse = reverse,
                speed = speed,
            )
            handler.post {
                try {
                    tex.initOnHandler()
                    callback(Result.success(tex))
                } catch (e: Throwable) {
                    tex.cleanupAfterFailedInitOnHandler()
                    callback(Result.failure(e))
                }
            }
        }
    }
}
