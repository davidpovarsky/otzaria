import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  private static let externalActivationChannelName = "otzaria/external_activation"
  private static let getPendingUriStringsMethod = "getPendingUriStrings"
  private static let externalActivationMethod = "externalActivation"
  private static let supportedSchemes: Set<String> = ["otzaria", "zayit"]

  private var externalActivationChannel: FlutterMethodChannel?
  private var pendingExternalActivationUris: [String] = []
  private var isExternalActivationChannelReady = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    configureExternalActivationChannel()

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
