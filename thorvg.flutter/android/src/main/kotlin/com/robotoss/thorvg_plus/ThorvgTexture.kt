package com.robotoss.thorvg_plus

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import io.flutter.view.TextureRegistry

/**
 * One Lottie animation, rendered into a Flutter `Texture(textureId)`.
 *
 * **SurfaceProducer (since `thorvg_plus` 1.1.0)**: this type now uses
 * `TextureRegistry.createSurfaceProducer()` instead of the legacy
 * `createSurfaceTexture()`. On API 28+ the engine selects an
 * `ImageReader`/`HardwareBuffer`-backed implementation, sidestepping the
 * `BufferQueue` fence-FD pipeline that exhausted the per-process FD budget
 * after a few minutes of fast scrolling under the previous renderer
 * (flutter/flutter#94916, flutter-webrtc/flutter-webrtc#1948). On API < 28
 * the engine transparently falls back to `SurfaceTexture`, so we keep the
 * same `ANativeWindow_lock`/`unlockAndPost` blit path either way — the
 * difference lives entirely below our JNI bridge.
 *
 * **Threading invariant**: every call into the JNI bridge across **all**
 * textures runs on the plugin's shared render handler. thorvg is initialized
 * with `TaskScheduler::threads() == 0`, which disables every internal
 * `ScopedLock` (see `tvgLock.h:38-42`); this leaves the global `LoaderMgr`
 * loader list and other shared structures unprotected. The previous
 * per-texture `HandlerThread` design crashed inside `canvas->update()` when
 * 8 animations loaded in parallel and raced on this state.
 *
 * **Surface lifecycle**: with `SurfaceProducer` the engine may destroy and
 * later recreate the underlying `Surface` independently of our widget's
 * mount lifetime — most commonly when the app moves to background and then
 * resumes. We bridge those events through [SurfaceProducer.Callback] onto
 * the render handler: the cached `ANativeWindow*` is detached on
 * `onSurfaceDestroyed` and re-attached against the fresh surface on
 * `onSurfaceCreated`, with the last-rendered frame replayed so the user
 * doesn't see a black flash on resume.
 *
 * Single shared thread costs us core-level parallelism, but the primary
 * goal — keeping the Flutter UI isolate idle during scroll — is preserved
 * either way.
 */
internal class ThorvgTexture private constructor(
    private val producer: TextureRegistry.SurfaceProducer,
    private val handler: Handler,
    private val initialData: ByteArray,
    private var renderWidth: Int,
    private var renderHeight: Int,
    private val animate: Boolean,
    private val repeat: Boolean,
    private val reverse: Boolean,
    private val speed: Double,
) {

    val id: Long = producer.id()

    var totalFrame: Float = 0f
        private set
    var duration: Float = 0f
        private set
    var lottieWidth: Int = 0
        private set
    var lottieHeight: Int = 0
        private set

    /** Native pointer; 0 before init or after destroy. Touched only from [handler]. */
    private var nativeHandle: Long = 0L

    @Volatile private var disposed: Boolean = false
    @Volatile private var initialized: Boolean = false

    /** Animation state — touched only from [handler]. */
    private var playing: Boolean = false
    private var startTimeMs: Long = 0L
    private var lastFrameRendered: Float = Float.NaN
    private var nextRunTime: Long = 0L

    /**
     * Tracks whether the JNI side currently holds an `ANativeWindow*` for
     * this handle. Touched only from [handler]. Goes false on
     * `onSurfaceDestroyed` and back to true after a successful re-attach.
     */
    private var surfaceAttached: Boolean = false

    /**
     * Bridges the platform-thread [SurfaceProducer.Callback] onto our
     * render handler so that all JNI work stays on the single thorvg
     * thread.
     *
     * We override the pre-3.27 method names (`onSurfaceCreated`,
     * `onSurfaceDestroyed`) so a single override path works across
     * Flutter 3.24..current: in 3.24-3.26 the framework calls these
     * methods directly; in 3.27+ the framework calls the new
     * `onSurfaceAvailable` / `onSurfaceCleanup`, whose default impls
     * delegate to the deprecated names. When this package eventually
     * raises its min Flutter past the deprecation removal window, swap
     * to the new names and drop the suppression.
     */
    private val producerCallback = object : TextureRegistry.SurfaceProducer.Callback {
        @Suppress("OVERRIDE_DEPRECATION")
        override fun onSurfaceCreated() {
            if (disposed) return
            handler.post {
                if (disposed || !initialized) return@post
                val newSurface = producer.surface
                if (newSurface == null) {
                    Log.w(
                        TAG,
                        "onSurfaceCreated fired but producer.surface is null; skipping reattach",
                    )
                    return@post
                }
                if (!nativeAttachSurface(nativeHandle, newSurface)) {
                    Log.e(TAG, "nativeAttachSurface failed during onSurfaceCreated reattach")
                    return@post
                }
                surfaceAttached = true
                // Replay the last frame so the user doesn't see a black
                // tile until the next tick fires (especially relevant on
                // background -> foreground when the ticker may be paused
                // and the next animate is hundreds of ms away).
                val resumeFrame = if (lastFrameRendered.isNaN()) 0f else lastFrameRendered
                renderFrame(resumeFrame, force = true)
            }
        }

        @Suppress("OVERRIDE_DEPRECATION")
        override fun onSurfaceDestroyed() {
            if (disposed) return
            handler.post {
                if (disposed || !initialized) return@post
                if (surfaceAttached && nativeHandle != 0L) {
                    nativeDetachSurface(nativeHandle)
                    surfaceAttached = false
                }
            }
        }
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
            // SurfaceProducer.setSize is the modern equivalent of
            // SurfaceTexture.setDefaultBufferSize. The engine forwards
            // the call to the underlying surface implementation
            // (ImageReader on API 28+, SurfaceTexture below), so we
            // don't need to know which path is active.
            producer.setSize(w, h)
            nativeResize(nativeHandle, w, h)
            val resumeFrame = if (lastFrameRendered.isNaN()) 0f else lastFrameRendered
            renderFrame(resumeFrame, force = true)
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        // Two-phase teardown to avoid racing with Flutter's raster thread.
        //
        // Phase 1 (render thread): stop scheduling new frames, detach the
        // cached ANativeWindow, and tear down the native handle. After
        // this returns, no more ANativeWindow_unlockAndPost calls will be
        // made on the surface, so any frames still in flight on the
        // consumer side can drain cleanly.
        //
        // Phase 2 (main thread): release the SurfaceProducer. The
        // producer is documented to be torn down on the platform (main)
        // thread — calling it from the render handler thread leaks fence
        // file descriptors and (under the legacy SurfaceTexture path)
        // eventually crashed the raster thread inside
        // `SurfaceTexture.updateTexImage` with "error dup'ing native
        // fence fd". Posting back to the main looper makes the cleanup
        // a regular platform-thread message, ordered after any in-
        // flight texture delivery.
        handler.post {
            handler.removeCallbacks(tickRunnable)
            if (nativeHandle != 0L) {
                // Releases the cached ANativeWindow and tears down the
                // thorvg side. After this point no more frames can be
                // produced for this handle.
                nativeDestroy(nativeHandle)
                nativeHandle = 0L
            }
            surfaceAttached = false
            Handler(Looper.getMainLooper()).post {
                // SurfaceProducer.release() releases the surface it owns
                // — we do NOT hold a separate Surface reference to free
                // (unlike the old SurfaceTextureEntry path).
                try { producer.release() } catch (_: Throwable) {}
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
        // Cache an ANativeWindow ref for the producer's surface once,
        // here, instead of grabbing one per frame. Per-frame
        // ANativeWindow_fromSurface causes binder transactions that
        // occasionally retain fence file descriptors and exhausts the
        // per-process fd budget after a few minutes of 60 Hz scrolling.
        // See jni_bridge.cpp's `g_windows` comment for the full incident.
        val surface = producer.surface
            ?: run {
                nativeDestroy(nativeHandle)
                nativeHandle = 0L
                throw IllegalStateException("producer.surface == null at init")
            }
        if (!nativeAttachSurface(nativeHandle, surface)) {
            nativeDestroy(nativeHandle)
            nativeHandle = 0L
            throw IllegalStateException("nativeAttachSurface failed")
        }
        surfaceAttached = true
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
        // Mirror the dispose split: cleanup of the SurfaceProducer must
        // run on the main (platform) thread, not on the render handler
        // thread.
        Handler(Looper.getMainLooper()).post {
            try { producer.release() } catch (_: Throwable) {}
        }
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
        if (disposed || nativeHandle == 0L || !surfaceAttached) return
        val rounded = if (totalFrame >= 1f) Math.round(frame).toFloat() else frame
        if (!force && rounded == lastFrameRendered) return
        nativeRenderFrame(nativeHandle, rounded, renderWidth, renderHeight)
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
    private external fun nativeAttachSurface(handle: Long, surface: Surface): Boolean
    private external fun nativeDetachSurface(handle: Long)
    private external fun nativeRenderFrame(
        handle: Long,
        frameNo: Float,
        w: Int,
        h: Int,
    ): Boolean

    companion object {
        private const val TAG = "ThorvgTexture"
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
            // SurfaceProducer is the modern, Impeller-compatible
            // alternative to SurfaceTexture (Flutter 3.22 landed, 3.24
            // stable). On API 28+ the engine picks an
            // ImageReader/HardwareBuffer-backed implementation, which is
            // not affected by the BufferQueue fence-FD leak that
            // crashed long scrolls under createSurfaceTexture (see
            // flutter/flutter#94916).
            val producer = registry.createSurfaceProducer().apply {
                setSize(width, height)
            }
            val tex = ThorvgTexture(
                producer = producer,
                handler = handler,
                initialData = data,
                renderWidth = width,
                renderHeight = height,
                animate = animate,
                repeat = repeat,
                reverse = reverse,
                speed = speed,
            )
            // Wire the SurfaceProducer.Callback before posting init.
            // The engine never invokes the callback synchronously from
            // setCallback, but having it set means that if the surface
            // is destroyed/recreated while init is queued on the
            // handler, the resulting onSurfaceDestroyed/onSurfaceCreated
            // events will land in order against `surfaceAttached`.
            producer.setCallback(tex.producerCallback)
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
