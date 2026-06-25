import UIKit
import Flutter
import CoreSpotlight
import AppIntents

@main
@objc class AppDelegate: FlutterAppDelegate {
  private static let externalActivationChannelName = "otzaria/external_activation"
  private static let getPendingUriStringsMethod = "getPendingUriStrings"
  private static let externalActivationMethod = "externalActivation"
  private static let supportedSchemes: Set<String> = ["otzaria", "zayit"]

  private static let spotlightChannelName = "otzaria/spotlight"
  private static let spotlightIndexBooksMethod = "indexBooks"
  private static let spotlightDomainIdentifier = "otzaria.books"

  private static let appStateChannelName = "otzaria/app_state"
  private static let appStateUpdateSnapshotMethod = "updateSnapshot"
  static let appStateDefaultsKey = "otzaria.currentStateSnapshot"

  private var externalActivationChannel: FlutterMethodChannel?
  private var pendingExternalActivationUris: [String] = []
  private var isExternalActivationChannelReady = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    configureExternalActivationChannel()
    configureSpotlightChannel()
    configureAppStateChannel()

    if let launchUrl = launchOptions?[.url] as? URL {
      enqueueExternalActivation(url: launchUrl)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    let handled = enqueueExternalActivation(url: url)
    return super.application(app, open: url, options: options) || handled
  }

  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if userActivity.activityType == CSSearchableItemActionType,
       let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
       let url = URL(string: identifier) {
      return enqueueExternalActivation(url: url)
    }

    return super.application(
      application,
      continue: userActivity,
      restorationHandler: restorationHandler
    )
  }

  private func configureExternalActivationChannel() {
    guard
      let controller = window?.rootViewController as? FlutterViewController
    else {
      return
    }

    let channel = FlutterMethodChannel(
      name: Self.externalActivationChannelName,
      binaryMessenger: controller.binaryMessenger
    )

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result([])
        return
      }

      switch call.method {
      case Self.getPendingUriStringsMethod:
        self.isExternalActivationChannelReady = true
        let pendingUris = self.pendingExternalActivationUris
        self.pendingExternalActivationUris.removeAll()
        result(pendingUris)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    externalActivationChannel = channel
  }

  private func configureSpotlightChannel() {
    guard
      let controller = window?.rootViewController as? FlutterViewController
    else {
      return
    }

    let channel = FlutterMethodChannel(
      name: Self.spotlightChannelName,
      binaryMessenger: controller.binaryMessenger
    )

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(
          code: "SPOTLIGHT_UNAVAILABLE",
          message: "Spotlight bridge is not available",
          details: nil
        ))
        return
      }

      switch call.method {
      case Self.spotlightIndexBooksMethod:
        guard let arguments = call.arguments as? [String: Any] else {
          result(FlutterError(
            code: "INVALID_ARGUMENTS",
            message: "Expected Spotlight indexing arguments",
            details: nil
          ))
          return
        }
        self.handleSpotlightIndexBooks(arguments: arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func configureAppStateChannel() {
    guard
      let controller = window?.rootViewController as? FlutterViewController
    else {
      return
    }

    let channel = FlutterMethodChannel(
      name: Self.appStateChannelName,
      binaryMessenger: controller.binaryMessenger
    )

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case Self.appStateUpdateSnapshotMethod:
        guard let snapshot = call.arguments as? [String: Any] else {
          result(FlutterError(
            code: "INVALID_ARGUMENTS",
            message: "Expected app state snapshot",
            details: nil
          ))
          return
        }
        Self.saveAppStateSnapshot(snapshot)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func saveAppStateSnapshot(_ snapshot: [String: Any]) {
    var payload = snapshot
    payload["nativeSavedAt"] = ISO8601DateFormatter().string(from: Date())

    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
          let jsonString = String(data: data, encoding: .utf8) else {
      return
    }

    UserDefaults.standard.set(jsonString, forKey: appStateDefaultsKey)
  }

  private func handleSpotlightIndexBooks(
    arguments: [String: Any],
    result: @escaping FlutterResult
  ) {
    let reset = arguments["reset"] as? Bool ?? false
    let rawItems = arguments["items"] as? [[String: Any]] ?? []

    let indexItems = rawItems.compactMap(makeSpotlightItem)

    let indexBlock = {
      guard !indexItems.isEmpty else {
        result(nil)
        return
      }

      CSSearchableIndex.default().indexSearchableItems(indexItems) { error in
        if let error = error {
          result(FlutterError(
            code: "SPOTLIGHT_INDEX_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
          return
        }
        result(nil)
      }
    }

    if reset {
      CSSearchableIndex.default().deleteSearchableItems(
        withDomainIdentifiers: [Self.spotlightDomainIdentifier]
      ) { error in
        if let error = error {
          result(FlutterError(
            code: "SPOTLIGHT_RESET_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
          return
        }
        indexBlock()
      }
    } else {
      indexBlock()
    }
  }

  private func makeSpotlightItem(from rawItem: [String: Any]) -> CSSearchableItem? {
    guard
      let uniqueIdentifier = rawItem["id"] as? String,
      let title = rawItem["title"] as? String,
      !uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }

    let subtitle = Self.cleanMetadataText(rawItem["subtitle"] as? String)
    let author = Self.cleanMetadataText(rawItem["author"] as? String)
    let keywords = rawItem["keywords"] as? [String]
    let kind = rawItem["kind"] as? String

    let attributeSet = CSSearchableItemAttributeSet(itemContentType: "public.text")
    attributeSet.title = title
    attributeSet.displayName = title
    attributeSet.contentDescription = subtitle
    attributeSet.namedLocation = author
    attributeSet.authorNames = author.map { [$0] }
    attributeSet.keywords = keywords
    attributeSet.kind = kind == "pdf" ? "PDF" : "Book"

    return CSSearchableItem(
      uniqueIdentifier: uniqueIdentifier,
      domainIdentifier: Self.spotlightDomainIdentifier,
      attributeSet: attributeSet
    )
  }

  private static func cleanMetadataText(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
      return nil
    }
    return value
  }

  @discardableResult
  private func enqueueExternalActivation(url: URL) -> Bool {
    guard
      let scheme = url.scheme?.lowercased(),
      Self.supportedSchemes.contains(scheme)
    else {
      return false
    }

    let uriString = url.absoluteString
    guard isExternalActivationChannelReady else {
      pendingExternalActivationUris.append(uriString)
      return true
    }

    externalActivationChannel?.invokeMethod(
      Self.externalActivationMethod,
      arguments: uriString
    )
    return true
  }
}

@available(iOS 16.0, *)
struct GetOtzariaStateIntent: AppIntent {
  static var title: LocalizedStringResource = "Get Otzaria State"
  static var description = IntentDescription("Returns the latest screen and open tab state from Otzaria.")
  static var openAppWhenRun: Bool = false

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let json = UserDefaults.standard.string(forKey: AppDelegate.appStateDefaultsKey) ?? "{}"
    return .result(value: json)
  }
}

@available(iOS 16.0, *)
struct OtzariaShortcutsProvider: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: GetOtzariaStateIntent(),
      phrases: [
        "Get \\(.applicationName) state",
        "What is open in \\(.applicationName)"
      ],
      shortTitle: "Get State",
      systemImageName: "book"
    )
  }
}
