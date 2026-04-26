package com.robotoss.thorvg_plus

import android.os.Handler
import android.os.HandlerThread
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry

/**
 * Method-channel host for the Texture-based renderer.
 *
 * **Single shared render thread**: thorvg's lock implementation is a no-op
 * unless `TaskScheduler::threads() > 0`, and we initialize it with 0 worker
 * threads. To keep cross-instance global state (LoaderMgr, Initializer
 * refcount) safe, every JNI call across every texture runs on this one
 * `HandlerThread`. The Flutter UI isolate is still freed; we trade
 * intra-screen parallelism for correctness.
 *
 * The legacy `dart:ffi` path that drives `Lottie` via `CustomPaint` is
 * unaffected and remains usable in parallel.
 */
class ThorvgPlusPlugin : FlutterPlugin, MethodCallHandler {

    companion object {
        const val CHANNEL = "thorvg_plus/texture"

        init {
            // Resolves at class-load time so a missing or mis-packaged native
            // binary surfaces as a clear `UnsatisfiedLinkError` immediately
            // rather than as an opaque JNI failure on the first method call.
            System.loadLibrary("thorvg")
        }
    }

    private var channel: MethodChannel? = null
    private var textureRegistry: TextureRegistry? = null
    private val textures = HashMap<Long, ThorvgTexture>()

    private var renderThread: HandlerThread? = null
    private var renderHandler: Handler? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler(this@ThorvgPlusPlugin)
        }
        textureRegistry = binding.textureRegistry

        val t = HandlerThread("thorvg-render").apply { start() }
        renderThread = t
        renderHandler = Handler(t.looper)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        synchronized(textures) {
            textures.values.toList().forEach { runCatching { it.dispose() } }
            textures.clear()
        }
        channel?.setMethodCallHandler(null)
        channel = null
        textureRegistry = null

        // Drain any in-flight render/dispose tasks before stopping the
        // looper, so we don't strand a thorvg destroy call.
        renderHandler = null
        renderThread?.quitSafely()
        renderThread = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "create" -> handleCreate(call, result)
            "play" -> handleSimple(call, result) { it.play() }
            "pause" -> handleSimple(call, result) { it.pause() }
            "dispose" -> handleDispose(call, result)
            "seek" -> handleSeek(call, result)
            "resize" -> handleResize(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleCreate(call: MethodCall, result: Result) {
        val registry = textureRegistry
        val handler = renderHandler
        if (registry == null || handler == null) {
            result.error("NO_REGISTRY", "Plugin not attached", null)
            return
        }
        val data = call.argument<ByteArray>("data")
        val width = call.argument<Int>("width") ?: 0
        val height = call.argument<Int>("height") ?: 0
        val animate = call.argument<Boolean>("animate") ?: true
        val repeat = call.argument<Boolean>("repeat") ?: true
        val reverse = call.argument<Boolean>("reverse") ?: false
        val speed = call.argument<Double>("speed") ?: 1.0

        if (data == null || data.isEmpty()) {
            result.error("BAD_ARGS", "missing 'data'", null)
            return
        }
        if (width <= 0 || height <= 0) {
            result.error("BAD_ARGS", "width/height must be > 0 (got ${width}x${height})", null)
            return
        }

        ThorvgTexture.createAsync(
            registry = registry,
            handler = handler,
            data = data,
            width = width,
            height = height,
            animate = animate,
            repeat = repeat,
            reverse = reverse,
            speed = speed,
        ) { texResult ->
            texResult.fold(
                onSuccess = { tex ->
                    synchronized(textures) { textures[tex.id] = tex }
                    result.success(
                        mapOf(
                            "textureId" to tex.id,
                            "lottieWidth" to tex.lottieWidth,
                            "lottieHeight" to tex.lottieHeight,
                            "totalFrame" to tex.totalFrame.toDouble(),
                            "duration" to tex.duration.toDouble(),
                        )
                    )
                },
                onFailure = { e ->
                    result.error("CREATE_FAILED", e.message ?: e.toString(), null)
                }
            )
        }
    }

    private inline fun handleSimple(
        call: MethodCall,
        result: Result,
        action: (ThorvgTexture) -> Unit,
    ) {
        val id = (call.arguments as? Map<*, *>)?.get("textureId") as? Number
        if (id == null) {
            result.error("BAD_ARGS", "missing 'textureId'", null)
            return
        }
        val tex = synchronized(textures) { textures[id.toLong()] }
        if (tex == null) {
            result.error("NOT_FOUND", "no texture for id $id", null)
            return
        }
        runCatching { action(tex) }
            .onSuccess { result.success(null) }
            .onFailure { result.error("CALL_FAILED", it.message, null) }
    }

    private fun handleDispose(call: MethodCall, result: Result) {
        val id = (call.arguments as? Map<*, *>)?.get("textureId") as? Number
        if (id == null) {
            result.error("BAD_ARGS", "missing 'textureId'", null)
            return
        }
        val tex = synchronized(textures) { textures.remove(id.toLong()) }
        if (tex == null) {
            // already disposed — treat as success
            result.success(null)
            return
        }
        runCatching { tex.dispose() }
            .onSuccess { result.success(null) }
            .onFailure { result.error("DISPOSE_FAILED", it.message, null) }
    }

    private fun handleSeek(call: MethodCall, result: Result) {
        val id = call.argument<Number>("textureId")
        val frame = call.argument<Number>("frame")
        if (id == null || frame == null) {
            result.error("BAD_ARGS", "need 'textureId' and 'frame'", null)
            return
        }
        val tex = synchronized(textures) { textures[id.toLong()] }
        if (tex == null) {
            result.error("NOT_FOUND", "no texture for id $id", null)
            return
        }
        tex.seek(frame.toFloat())
        result.success(null)
    }

    private fun handleResize(call: MethodCall, result: Result) {
        val id = call.argument<Number>("textureId")
        val w = call.argument<Number>("width")
        val h = call.argument<Number>("height")
        if (id == null || w == null || h == null) {
            result.error("BAD_ARGS", "need 'textureId', 'width', 'height'", null)
            return
        }
        val tex = synchronized(textures) { textures[id.toLong()] }
        if (tex == null) {
            result.error("NOT_FOUND", "no texture for id $id", null)
            return
        }
        tex.resize(w.toInt(), h.toInt())
        result.success(null)
    }
}
