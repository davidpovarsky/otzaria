import AppIntents
import Foundation

@available(iOSApplicationExtension 16.0, *)
struct OtzariaExtensionPingIntent: AppIntent {
  static var title: LocalizedStringResource = "Otzaria Extension Ping"
  static var description = IntentDescription("Returns a fixed response from the Otzaria App Intents extension.")
  static var openAppWhenRun: Bool = false

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let wroteProbe = OtzariaAppGroup.writeProbe(source: "OtzariaIntentsExtension")
    return .result(value: OtzariaAppGroup.jsonString(from: [
      "ok": true,
      "source": "OtzariaIntentsExtension",
      "appGroup": OtzariaAppGroup.identifier,
      "wroteProbe": wroteProbe,
      "probe": OtzariaAppGroup.readProbe() ?? ""
    ]))
  }
}

@available(iOSApplicationExtension 16.0, *)
struct OtzariaExtensionShortcutsProvider: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OtzariaExtensionPingIntent(),
      phrases: [
        "Ping \(.applicationName) extension"
      ],
      shortTitle: "Ping Extension",
      systemImageName: "bolt"
    )
  }
}
