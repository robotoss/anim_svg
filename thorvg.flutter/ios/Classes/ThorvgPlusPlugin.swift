import Flutter
import UIKit

/// Method-channel host for the Texture-based renderer on iOS.
///
/// Mirrors the Android `ThorvgPlusPlugin`:
///   - one shared `MethodChannel` per engine,
///   - a registry of `ThorvgTexture` instances keyed by `textureId`,
///   - each texture owns its own `DispatchQueue` and `CVPixelBufferPool`,
///   - rasterization happens on the texture's queue, never on the main isolate.
///
/// The legacy `dart:ffi` path is unchanged and continues to work in parallel.
public class ThorvgPlusPlugin: NSObject, FlutterPlugin {

    private static let channelName = "thorvg_plus/texture"

    private let textureRegistry: FlutterTextureRegistry
    private var textures: [Int64: ThorvgTexture] = [:]
    private let texturesLock = NSLock()

    /// Shared render queue. thorvg's internal locks are no-ops while
    /// `TaskScheduler::threads() == 0`, so cross-instance global state
    /// (LoaderMgr, Initializer refcount, …) must be reached from one
    /// serial queue. Per-texture parallelism is sacrificed; the UI thread
    /// stays free, which is the primary goal.
    private let renderQueue = DispatchQueue(
        label: "io.thorvg.render", qos: .userInitiated
    )

    init(registry: FlutterTextureRegistry) {
        self.textureRegistry = registry
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = ThorvgPlusPlugin(registry: registrar.textures())
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "create":  handleCreate(call, result: result)
        case "play":    handleSimple(call, result: result) { $0.play() }
        case "pause":   handleSimple(call, result: result) { $0.pause() }
        case "dispose": handleDispose(call, result: result)
        case "seek":    handleSeek(call, result: result)
        case "resize":  handleResize(call, result: result)
        default:        result(FlutterMethodNotImplemented)
        }
    }

    private func handleCreate(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let dataAny = args["data"],
              let width = (args["width"] as? NSNumber)?.intValue,
              let height = (args["height"] as? NSNumber)?.intValue
        else {
            result(FlutterError(code: "BAD_ARGS", message: "missing data/width/height", details: nil))
            return
        }
        guard width > 0, height > 0 else {
            result(FlutterError(code: "BAD_ARGS", message: "width/height must be > 0", details: nil))
            return
        }

        let bytes: Data
        if let typed = dataAny as? FlutterStandardTypedData {
            bytes = typed.data
        } else if let raw = dataAny as? Data {
            bytes = raw
        } else {
            result(FlutterError(code: "BAD_ARGS", message: "'data' must be Uint8List", details: nil))
            return
        }

        let animate = (args["animate"] as? NSNumber)?.boolValue ?? true
        let repeats = (args["repeat"] as? NSNumber)?.boolValue ?? true
        let reverse = (args["reverse"] as? NSNumber)?.boolValue ?? false
        let speed = (args["speed"] as? NSNumber)?.doubleValue ?? 1.0

        // Run all native init (Initializer::init / SwCanvas::gen / load) on
        // the plugin's shared render queue. Reply over MethodChannel from
        // there — FlutterResult is thread-safe.
        ThorvgTexture.createAsync(
            registry: textureRegistry,
            queue: renderQueue,
            data: bytes,
            width: width,
            height: height,
            animate: animate,
            repeats: repeats,
            reverse: reverse,
            speed: speed
        ) { [weak self] texResult in
            switch texResult {
            case .success(let texture):
                self?.texturesLock.lock()
                self?.textures[texture.textureId] = texture
                self?.texturesLock.unlock()
                result([
                    "textureId": NSNumber(value: texture.textureId),
                    "lottieWidth": NSNumber(value: texture.lottieWidth),
                    "lottieHeight": NSNumber(value: texture.lottieHeight),
                    "totalFrame": NSNumber(value: Double(texture.totalFrame)),
                    "duration": NSNumber(value: Double(texture.duration)),
                ])
            case .failure(let error):
                result(FlutterError(code: "CREATE_FAILED", message: "\(error)", details: nil))
            }
        }
    }

    private func handleSimple(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult,
        action: (ThorvgTexture) -> Void
    ) {
        guard let id = textureId(from: call) else {
            result(FlutterError(code: "BAD_ARGS", message: "missing 'textureId'", details: nil))
            return
        }
        guard let texture = lookup(id) else {
            result(FlutterError(code: "NOT_FOUND", message: "no texture for id \(id)", details: nil))
            return
        }
        action(texture)
        result(nil)
    }

    private func handleDispose(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let id = textureId(from: call) else {
            result(FlutterError(code: "BAD_ARGS", message: "missing 'textureId'", details: nil))
            return
        }
        texturesLock.lock()
        let texture = textures.removeValue(forKey: id)
        texturesLock.unlock()
        texture?.dispose()
        result(nil)
    }

    private func handleSeek(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let id = (args["textureId"] as? NSNumber)?.int64Value,
              let frame = (args["frame"] as? NSNumber)?.floatValue
        else {
            result(FlutterError(code: "BAD_ARGS", message: "need 'textureId' and 'frame'", details: nil))
            return
        }
        guard let texture = lookup(id) else {
            result(FlutterError(code: "NOT_FOUND", message: "no texture for id \(id)", details: nil))
            return
        }
        texture.seek(frame: frame)
        result(nil)
    }

    private func handleResize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let id = (args["textureId"] as? NSNumber)?.int64Value,
              let w = (args["width"] as? NSNumber)?.intValue,
              let h = (args["height"] as? NSNumber)?.intValue
        else {
            result(FlutterError(code: "BAD_ARGS", message: "need textureId/width/height", details: nil))
            return
        }
        guard let texture = lookup(id) else {
            result(FlutterError(code: "NOT_FOUND", message: "no texture for id \(id)", details: nil))
            return
        }
        texture.resize(width: w, height: h)
        result(nil)
    }

    private func textureId(from call: FlutterMethodCall) -> Int64? {
        guard let args = call.arguments as? [String: Any] else { return nil }
        return (args["textureId"] as? NSNumber)?.int64Value
    }

    private func lookup(_ id: Int64) -> ThorvgTexture? {
        texturesLock.lock(); defer { texturesLock.unlock() }
        return textures[id]
    }
}
