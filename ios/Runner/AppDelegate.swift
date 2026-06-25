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
  static let spotlightDomainIdentifier = "otzaria.books"

  private static let appStateChannelName = "otzaria/app_state"
  private static let appStateUpdateSnapshotMethod = "updateSnapshot"
  static let appStateDefaultsKey = "otzaria.currentStateSnapshot"
  static let pendingShortcutURLDefaultsKey = "otzaria.pendingShortcutURL"

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
    drainPendingShortcutActivation()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    drainPendingShortcutActivation()
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

  static func makeOpenURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
    var components = URLComponents()
    components.scheme = "otzaria"
    components.host = "open"
    components.path = path
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    return components.url!
  }

  static func queueShortcutURL(_ url: URL) {
    UserDefaults.standard.set(url.absoluteString, forKey: pendingShortcutURLDefaultsKey)
  }

  static func loadAppStateSnapshot() -> [String: Any] {
    guard let jsonString = UserDefaults.standard.string(forKey: appStateDefaultsKey),
          let data = jsonString.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
      return [:]
    }
    return dictionary
  }

  static func jsonString(from object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8) else {
      return "{}"
    }
    return json
  }

  private func drainPendingShortcutActivation() {
    guard let uriString = UserDefaults.standard.string(forKey: Self.pendingShortcutURLDefaultsKey),
          let url = URL(string: uriString) else {
      return
    }
    UserDefaults.standard.removeObject(forKey: Self.pendingShortcutURLDefaultsKey)
    enqueueExternalActivation(url: url)
  }

  private func configureExternalActivationChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
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
    guard let controller = window?.rootViewController as? FlutterViewController else {
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
    guard let controller = window?.rootViewController as? FlutterViewController else {
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
enum OtzariaScreenOption: String, AppEnum {
  case library
  case search
  case tools
  case settings

  static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Otzaria Screen")
  static var caseDisplayRepresentations: [OtzariaScreenOption: DisplayRepresentation] = [
    .library: "Library",
    .search: "Search",
    .tools: "Tools",
    .settings: "Settings"
  ]

  var path: String {
    switch self {
    case .library: return "/library"
    case .search: return "/search"
    case .tools: return "/tools"
    case .settings: return "/settings"
    }
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
struct OpenOtzariaScreenIntent: AppIntent {
  static var title: LocalizedStringResource = "Open Otzaria Screen"
  static var description = IntentDescription("Opens a top-level screen in Otzaria.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Screen") var screen: OtzariaScreenOption

  func perform() async throws -> some IntentResult {
    AppDelegate.queueShortcutURL(AppDelegate.makeOpenURL(path: screen.path))
    return .result()
  }
}

@available(iOS 16.0, *)
struct OpenOtzariaSearchIntent: AppIntent {
  static var title: LocalizedStringResource = "Open Otzaria Search"
  static var description = IntentDescription("Opens Otzaria search with a query.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Query") var query: String

  func perform() async throws -> some IntentResult {
    AppDelegate.queueShortcutURL(
      AppDelegate.makeOpenURL(
        path: "/search",
        queryItems: [URLQueryItem(name: "q", value: query)]
      )
    )
    return .result()
  }
}

@available(iOS 16.0, *)
struct OpenOtzariaRefIntent: AppIntent {
  static var title: LocalizedStringResource = "Open Otzaria Ref"
  static var description = IntentDescription("Opens Otzaria source detection with a reference query.")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Reference") var reference: String

  func perform() async throws -> some IntentResult {
    AppDelegate.queueShortcutURL(
      AppDelegate.makeOpenURL(
        path: "/detection",
        queryItems: [URLQueryItem(name: "q", value: reference)]
      )
    )
    return .result()
  }
}

@available(iOS 16.0, *)
struct GetCurrentOtzariaBookIntent: AppIntent {
  static var title: LocalizedStringResource = "Get Current Otzaria Book"
  static var description = IntentDescription("Returns the current open book or tab title from Otzaria.")
  static var openAppWhenRun: Bool = false

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let snapshot = AppDelegate.loadAppStateSnapshot()
    let title = snapshot["currentTabTitle"] as? String ?? ""
    return .result(value: title)
  }
}

@available(iOS 16.0, *)
struct GetOpenOtzariaTabsIntent: AppIntent {
  static var title: LocalizedStringResource = "Get Open Otzaria Tabs"
  static var description = IntentDescription("Returns the open Otzaria tab titles as JSON.")
  static var openAppWhenRun: Bool = false

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let snapshot = AppDelegate.loadAppStateSnapshot()
    let titles = snapshot["openTabsTitles"] as? [String] ?? []
    return .result(value: AppDelegate.jsonString(from: titles))
  }
}

@available(iOS 16.0, *)
struct SearchOtzariaBooksIntent: AppIntent {
  static var title: LocalizedStringResource = "Search Otzaria Books"
  static var description = IntentDescription("Searches indexed Otzaria books and returns matching items as JSON.")
  static var openAppWhenRun: Bool = false

  @Parameter(title: "Query") var query: String
  @Parameter(title: "Limit") var limit: Int

  init() {
    self.query = ""
    self.limit = 10
  }

  init(query: String, limit: Int = 10) {
    self.query = query
    self.limit = limit
  }

  func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let results = await Self.searchBooks(query: query, limit: limit)
    return .result(value: AppDelegate.jsonString(from: results))
  }

  private static func searchBooks(query rawQuery: String, limit rawLimit: Int) async -> [[String: String]] {
    let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let limit = min(max(rawLimit, 1), 50)
    let escaped = trimmed
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let queryString = "title == \"*\(escaped)*\"cd || contentDescription == \"*\(escaped)*\"cd || namedLocation == \"*\(escaped)*\"cd"

    return await withCheckedContinuation { continuation in
      var results: [[String: String]] = []
      let searchQuery = CSSearchQuery(
        queryString: queryString,
        attributes: ["title", "contentDescription", "namedLocation", "kind"]
      )

      searchQuery.foundItemsHandler = { items in
        for item in items where results.count < limit {
          guard item.domainIdentifier == AppDelegate.spotlightDomainIdentifier else { continue }
          let attributes = item.attributeSet
          results.append([
            "title": attributes.title ?? "",
            "path": attributes.contentDescription ?? "",
            "author": attributes.namedLocation ?? "",
            "kind": attributes.kind ?? "",
            "deepLink": item.uniqueIdentifier
          ])
        }
      }

      searchQuery.completionHandler = { _ in
        continuation.resume(returning: results)
      }
      searchQuery.start()
    }
  }
}

@available(iOS 16.0, *)
struct OtzariaShortcutsProvider: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    [
      AppShortcut(
        intent: GetOtzariaStateIntent(),
        phrases: [
          "Get \(.applicationName) state",
          "What is open in \(.applicationName)"
        ],
        shortTitle: "Get State",
        systemImageName: "book"
      ),
      AppShortcut(
        intent: OpenOtzariaScreenIntent(),
        phrases: [
          "Open \(.applicationName) screen"
        ],
        shortTitle: "Open Screen",
        systemImageName: "rectangle.grid.2x2"
      ),
      AppShortcut(
        intent: OpenOtzariaSearchIntent(),
        phrases: [
          "Search in \(.applicationName)"
        ],
        shortTitle: "Search",
        systemImageName: "magnifyingglass"
      ),
      AppShortcut(
        intent: OpenOtzariaRefIntent(),
        phrases: [
          "Open reference in \(.applicationName)"
        ],
        shortTitle: "Open Ref",
        systemImageName: "text.book.closed"
      ),
      AppShortcut(
        intent: GetCurrentOtzariaBookIntent(),
        phrases: [
          "Get current book in \(.applicationName)"
        ],
        shortTitle: "Current Book",
        systemImageName: "book.closed"
      ),
      AppShortcut(
        intent: GetOpenOtzariaTabsIntent(),
        phrases: [
          "Get open tabs in \(.applicationName)"
        ],
        shortTitle: "Open Tabs",
        systemImageName: "square.on.square"
      ),
      AppShortcut(
        intent: SearchOtzariaBooksIntent(),
        phrases: [
          "Search books in \(.applicationName)"
        ],
        shortTitle: "Search Books",
        systemImageName: "books.vertical"
      )
    ]
  }
}
