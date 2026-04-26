import Flutter
import CoreVideo
import QuartzCore

enum ThorvgTextureError: Error {
    case nativeCreateFailed
    case loadFailed(String)
    case pixelBufferPoolFailed
}

/// One Lottie animation, rendered into a Flutter `Texture(textureId)` on iOS.
///
/// **Threading invariant**: every C++ call for a given instance runs on the
/// texture's own serial `DispatchQueue`. thorvg's per-instance state
/// (canvas, animation, picture, scratch buffers) is not safe to touch from
/// a thread other than the one that allocated it.
///
/// Use [ThorvgTexture.createAsync] to construct: the texture is registered
/// with the Flutter texture registry synchronously to obtain a `textureId`,
/// then `ThorvgBridge.create` and `ThorvgBridge.load` run on the queue. The
/// completion callback fires once meta is ready (success) or init has failed.
final class ThorvgTexture: NSObject, FlutterTexture {

    private(set) var textureId: Int64 = 0
    var totalFrame: Float = 0
    var duration: Float = 0
    var lottieWidth: Int = 0
    var lottieHeight: Int = 0

    private weak var registry: FlutterTextureRegistry?
    private var nativeHandle: intptr_t = 0

    private let initialData: Data
    private var renderWidth: Int
    private var renderHeight: Int
    private let animate: Bool
    private let repeats: Bool
    private let reverse: Bool
    private let speed: Double

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var pixelBufferPool: CVPixelBufferPool?

    private let bufferLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?

    private var startTimeMs: Int64 = 0
    private var lastFrameRendered: Float = .nan
    private var disposed = false
    private var initialized = false
    private var playing = false

    private init(
        registry: FlutterTextureRegistry,
        queue: DispatchQueue,
        data: Data,
        width: Int,
        height: Int,
        animate: Bool,
        repeats: Bool,
        reverse: Bool,
        speed: Double
    ) {
        self.registry = registry
        self.initialData = data
        self.renderWidth = width
        self.renderHeight = height
        self.animate = animate
        self.repeats = repeats
        self.reverse = reverse
        self.speed = speed
        self.queue = queue
        super.init()
    }

    deinit {
        if !disposed { dispose() }
    }

    // MARK: FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        if let buf = latestPixelBuffer {
            return Unmanaged.passRetained(buf)
        }
        return nil
    }

    // MARK: Public API (callable from any thread)

    func play() {
        guard !disposed else { return }
        queue.async { [weak self] in
            guard let self = self, !self.disposed, self.initialized else { return }
            self.startPlayingOnQueue()
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.playing = false
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func seek(frame: Float) {
        guard !disposed else { return }
        queue.async { [weak self] in
            guard let self = self, !self.disposed, self.initialized else { return }
            self.playing = false
            self.timer?.cancel()
            self.timer = nil
            self.renderFrameOnQueue(frame, force: true)
        }
    }

    func resize(width: Int, height: Int) {
        guard !disposed, width > 0, height > 0 else { return }
        queue.async { [weak self] in
            guard let self = self, !self.disposed, self.initialized else { return }
            if self.renderWidth == width && self.renderHeight == height { return }
            self.renderWidth = width
            self.renderHeight = height
            ThorvgBridge.resize(self.nativeHandle, width: Int32(width), height: Int32(height))
            self.pixelBufferPool = Self.makePixelBufferPool(width: width, height: height)
            let last = self.lastFrameRendered.isNaN ? 0 : self.lastFrameRendered
            self.renderFrameOnQueue(last, force: true)
        }
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        let id = textureId
        let registry = self.registry
        queue.async { [weak self] in
            guard let self = self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.bufferLock.lock()
            self.latestPixelBuffer = nil
            self.bufferLock.unlock()
            if self.nativeHandle != 0 {
                ThorvgBridge.destroy(self.nativeHandle)
                self.nativeHandle = 0
            }
            DispatchQueue.main.async {
                registry?.unregisterTexture(id)
            }
        }
    }

    // MARK: Init on queue

    private func initOnQueue() throws {
        let h = ThorvgBridge.create()
        if h == 0 {
            throw ThorvgTextureError.nativeCreateFailed
        }
        if !ThorvgBridge.load(
            h,
            data: initialData,
            width: Int32(renderWidth),
            height: Int32(renderHeight)
        ) {
            let err = ThorvgBridge.errorMessage(h)
            ThorvgBridge.destroy(h)
            throw ThorvgTextureError.loadFailed(err)
        }
        nativeHandle = h
        totalFrame = ThorvgBridge.totalFrame(h)
        duration = ThorvgBridge.duration(h)
        let sz = ThorvgBridge.size(h)
        lottieWidth = sz[0].intValue
        lottieHeight = sz[1].intValue

        guard let pool = Self.makePixelBufferPool(width: renderWidth, height: renderHeight) else {
            ThorvgBridge.destroy(h)
            nativeHandle = 0
            throw ThorvgTextureError.pixelBufferPoolFailed
        }
        pixelBufferPool = pool
        initialized = true

        renderFrameOnQueue(0, force: true)
        if animate { startPlayingOnQueue() }
    }

    // MARK: Render loop

    private func startPlayingOnQueue() {
        playing = true
        startTimeMs = Self.uptimeMillis()
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + .milliseconds(Self.frameIntervalMs),
            repeating: .milliseconds(Self.frameIntervalMs),
            leeway: .milliseconds(2)
        )
        t.setEventHandler { [weak self] in self?.tickIfPlaying() }
        t.resume()
        timer = t
    }

    private func tickIfPlaying() {
        guard !disposed, playing, initialized else { return }
        let now = Self.uptimeMillis()
        let durSec = Double(duration)
        if durSec <= 0 || totalFrame <= 0 {
            renderFrameOnQueue(0, force: true)
            playing = false
            timer?.cancel()
            timer = nil
            return
        }

        let elapsedSec = Double(now - startTimeMs) / 1000.0
        let raw = elapsedSec / durSec * Double(totalFrame) * speed
        var current = reverse ? Float(Double(totalFrame) - raw) : Float(raw)

        let ended = reverse ? (current <= 0) : (current >= totalFrame)
        if ended {
            if repeats {
                startTimeMs = now
                current = reverse ? totalFrame : 0
            } else {
                renderFrameOnQueue(reverse ? 0 : (totalFrame - 1), force: true)
                playing = false
                timer?.cancel()
                timer = nil
                return
            }
        }
        renderFrameOnQueue(current, force: false)
    }

    private func renderFrameOnQueue(_ frame: Float, force: Bool) {
        guard !disposed, nativeHandle != 0 else { return }
        let rounded = totalFrame >= 1 ? roundf(frame) : frame
        if !force && rounded == lastFrameRendered { return }
        guard let pool = pixelBufferPool else { return }

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pool, &pixelBufferOut
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            // Pool exhausted (typically: previous frame still held by Flutter).
            // Skip this tick rather than block the queue.
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let ok = ThorvgBridge.renderFrame(
            nativeHandle,
            frameNo: rounded,
            width: Int32(renderWidth),
            height: Int32(renderHeight),
            intoBuffer: base,
            rowBytes: rowBytes
        )
        if !ok { return }

        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        bufferLock.unlock()
        lastFrameRendered = rounded
        registry?.textureFrameAvailable(textureId)
    }

    // MARK: Helpers

    private static let frameIntervalMs = 16

    private static func uptimeMillis() -> Int64 {
        return Int64(CACurrentMediaTime() * 1000)
    }

    private static func makePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3,
        ]
        var pool: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            attrs as CFDictionary,
            &pool
        )
        return result == kCVReturnSuccess ? pool : nil
    }

    // MARK: Async factory

    /// Constructs a `ThorvgTexture`, registers it with the Flutter texture
    /// registry, then runs all per-instance native init on the plugin's
    /// shared render `DispatchQueue`. The completion is invoked from that
    /// queue once init is done (success or failure).
    static func createAsync(
        registry: FlutterTextureRegistry,
        queue: DispatchQueue,
        data: Data,
        width: Int,
        height: Int,
        animate: Bool,
        repeats: Bool,
        reverse: Bool,
        speed: Double,
        completion: @escaping (Result<ThorvgTexture, Error>) -> Void
    ) {
        let tex = ThorvgTexture(
            registry: registry,
            queue: queue,
            data: data,
            width: width,
            height: height,
            animate: animate,
            repeats: repeats,
            reverse: reverse,
            speed: speed
        )
        tex.textureId = registry.register(tex)
        tex.queue.async {
            do {
                try tex.initOnQueue()
                completion(.success(tex))
            } catch {
                let id = tex.textureId
                let r = tex.registry
                tex.disposed = true
                tex.timer?.cancel()
                tex.timer = nil
                if tex.nativeHandle != 0 {
                    ThorvgBridge.destroy(tex.nativeHandle)
                    tex.nativeHandle = 0
                }
                DispatchQueue.main.async {
                    r?.unregisterTexture(id)
                }
                completion(.failure(error))
            }
        }
    }
}
