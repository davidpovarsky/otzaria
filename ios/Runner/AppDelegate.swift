import UIKit
import Flutter
import CoreSpotlight

@main
@objc class AppDelegate: FlutterAppDelegate {
  private static let externalActivationChannelName = "otzaria/external_activation"
  private static let getPendingUriStringsMethod = "getPendingUriStrings"
  private static let externalActivationMethod = "externalActivation"
  private static let supportedSchemes: Set<String> = ["otzaria", "zayit"]

  private static let spotlightChannelName = "otzaria/spotlight"
  private static let spotlightIndexBooksMethod = "indexBooks"
  private static let spotlightDomainIdentifier = "otzaria.books"

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
