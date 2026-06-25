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

    return super.application.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
