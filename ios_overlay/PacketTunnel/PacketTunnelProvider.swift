import Foundation
import LibXray // LibXray.xcframework built by scripts/build_cores.sh
import NetworkExtension

/// TUN-mode tunnel for iOS. The extension creates the utun interface through
/// NEPacketTunnelNetworkSettings, finds the file descriptor of that utun, and hands it
/// to Xray-core's native `tun` inbound (env `xray.tun.fd`).
///
/// iOS limits Network Extensions to roughly 50 MB of memory. Keep logging low and avoid
/// huge geo files (use a trimmed geosite.dat).
class PacketTunnelProvider: NEPacketTunnelProvider {
  private let appGroup = "group.io.surprise.vpn"

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
      return completionHandler(fail("App group container is not available"))
    }
    copyGeoFiles(to: dir)
    let cfg = dir.appendingPathComponent("config.json")
    let opts = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("opts.json")))) as? [String: Any] ?? [:]

    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "172.19.0.2")
    let v4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
    v4.includedRoutes = [NEIPv4Route.default()]
    settings.ipv4Settings = v4
    if (opts["ipv6"] as? Bool) == true {
      let v6 = NEIPv6Settings(addresses: ["fd00:1:fd00:1::1"], networkPrefixLengths: [126])
      v6.includedRoutes = [NEIPv6Route.default()]
      settings.ipv6Settings = v6
    }
    settings.dnsSettings = NEDNSSettings(servers: (opts["dns"] as? [String]) ?? ["1.1.1.1", "8.8.8.8"])
    settings.mtu = NSNumber(value: (opts["mtu"] as? Int) ?? 1500)

    setTunnelNetworkSettings(settings) { [weak self] error in
      guard let self = self else { return }
      if let error = error { return completionHandler(error) }
      guard let fd = self.tunnelFileDescriptor else { return completionHandler(self.fail("Could not find the tunnel file descriptor")) }

      let request: [String: Any] = [
        "apiVersion": 1,
        "method": "runXray",
        "env": ["xray.location.asset": dir.path, "xray.location.config": cfg.path, "xray.tun.fd": Int(fd)],
        "payload": ["datDir": dir.path, "configPath": cfg.path],
      ]
      guard let data = try? JSONSerialization.data(withJSONObject: request), let json = String(data: data, encoding: .utf8) else {
        return completionHandler(self.fail("Could not encode the Xray request"))
      }
      // gomobile exposes libXray's Invoke as LibXrayInvoke(_:). Verify against your build.
      let response = LibXrayInvoke(json)
      try? FileManager.default.removeItem(at: cfg) // keep keys off disk once read
      if let d = response.data(using: .utf8),
         let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
         (obj["success"] as? Bool) == true {
        completionHandler(nil)
      } else {
        completionHandler(self.fail("Xray failed to start: \(response)"))
      }
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    _ = LibXrayInvoke("{\"apiVersion\":1,\"method\":\"stopXray\"}")
    completionHandler()
  }

  // MARK: helpers
  private func fail(_ m: String) -> NSError {
    NSError(domain: "io.surprise.vpn", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
  }

  /// Finds the utun descriptor owned by this extension (same approach WireGuard uses).
  private var tunnelFileDescriptor: Int32? {
    var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
    for fd: Int32 in 0...1024 {
      var len = socklen_t(buf.count)
      // SYSPROTO_CONTROL = 2, UTUN_OPT_IFNAME = 2
      if getsockopt(fd, 2, 2, &buf, &len) == 0, String(cString: buf).hasPrefix("utun") { return fd }
    }
    return nil
  }

  private func copyGeoFiles(to dir: URL) {
    for n in ["geoip", "geosite"] {
      let dst = dir.appendingPathComponent("\(n).dat")
      if FileManager.default.fileExists(atPath: dst.path) { continue }
      if let src = Bundle.main.url(forResource: n, withExtension: "dat") { try? FileManager.default.copyItem(at: src, to: dst) }
    }
  }
}
