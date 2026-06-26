import Foundation

enum OtzariaAppGroup {
  static let identifier = "group.com.mendelg.otzaria"
  private static let probeFileName = "app-group-probe.json"

  static func containerURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
  }

  static func probeFileURL() -> URL? {
    containerURL()?.appendingPathComponent(probeFileName, isDirectory: false)
  }

  @discardableResult
  static func writeProbe(source: String) -> Bool {
    guard let url = probeFileURL() else {
      return false
    }

    let payload: [String: Any] = [
      "ok": true,
      "source": source,
      "appGroup": identifier,
      "writtenAt": ISO8601DateFormatter().string(from: Date())
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
      return false
    }

    do {
      try data.write(to: url, options: [.atomic])
      return true
    } catch {
      return false
    }
  }

  static func readProbe() -> String? {
    guard let url = probeFileURL(),
          let data = try? Data(contentsOf: url) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  static func jsonString(from object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
      return "{}"
    }
    return json
  }
}
