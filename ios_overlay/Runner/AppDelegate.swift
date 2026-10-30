import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
  private let appGroup = "group.io.surprise.vpn"
  private let extensionId = "io.surprise.vpn.PacketTunnel"
  private var manager: NETunnelProviderManager?
  private var sink: FlutterEventSink?
  private var observer: NSObjectProtocol?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let messenger = registrar(forPlugin: "XRayBridge")?.messenger() {
      FlutterMethodChannel(name: "io.surprise.vpn/core", binaryMessenger: messenger)
        .setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
      FlutterEventChannel(name: "io.surprise.vpn/events", binaryMessenger: messenger).setStreamHandler(self)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: Method channel
  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "prepare":
      loadManager { ok in result(ok) }
    case "start":
      guard let args = call.arguments as? [String: Any],
            let cfg = args["config"] as? String,
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
      else { return result(FlutterError(code: "bad_args", message: "Missing config or app group", details: nil)) }
      do {
        try cfg.write(to: container.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let opts = try JSONSerialization.data(withJSONObject: args["opts"] ?? [:])
        try opts.write(to: container.appendingPathComponent("opts.json"), options: .atomic)
        guard let m = manager else { return result(FlutterError(code: "no_manager", message: "Call prepare first", details: nil)) }
        try m.connection.startVPNTunnel()
        result(nil)
      } catch { result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil)) }
    case "stop":
      manager?.connection.stopVPNTunnel()
      result(nil)
    case "status":
      result(statusString(manager?.connection.status ?? .disconnected))
    case "installedApps":
      result([]) // iOS has no per-app VPN for third-party apps
    case "openVpnSettings", "openBatterySettings":
      if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Manager
  private func loadManager(_ done: @escaping (Bool) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { [weak self] list, error in
      guard let self = self, error == nil else { return done(false) }
      let m = list?.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.extensionId })
        ?? NETunnelProviderManager()
      let proto = NETunnelProviderProtocol()
      proto.providerBundleIdentifier = self.extensionId
      proto.serverAddress = "XRay VPN"
      m.protocolConfiguration = proto
      m.localizedDescription = "XRay VPN"
      m.isEnabled = true
      // Saving shows the system "Add VPN Configurations" prompt the first time.
      m.saveToPreferences { err in
        if err != nil { return done(false) }
        m.loadFromPreferences { err2 in
          self.manager = m
          self.observe(m)
          done(err2 == nil)
        }
      }
    }
  }

  private func observe(_ m: NETunnelProviderManager) {
    if let o = observer { NotificationCenter.default.removeObserver(o) }
    observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: m.connection, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.sink?(["type": "status", "state": self.statusString(m.connection.status)])
    }
  }

  private func statusString(_ s: NEVPNStatus) -> String {
    switch s {
    case .connected: return "connected"
    case .connecting, .reasserting: return "connecting"
    default: return "disconnected"
    }
  }

  // MARK: Event channel
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
