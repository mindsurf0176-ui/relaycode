import SwiftUI
import UIKit

@MainActor
final class RelayCodeBackgroundSessionEvents {
    static let shared = RelayCodeBackgroundSessionEvents()

    private var completionHandlers: [String: () -> Void] = [:]

    func store(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        completionHandlers[identifier] = completionHandler
    }

    func finish(identifier: String?) {
        guard let identifier,
              let completionHandler = completionHandlers.removeValue(
                  forKey: identifier
              ) else {
            return
        }
        completionHandler()
    }
}

@MainActor
final class RelayCodeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        RelayCodeBackgroundSessionEvents.shared.store(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}

@main
struct RelayCodeApp: App {
    @UIApplicationDelegateAdaptor(RelayCodeAppDelegate.self)
    private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var onDeviceModel = OnDeviceModelService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(onDeviceModel)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didReceiveMemoryWarningNotification
                    )
                ) { _ in
                    Task {
                        await onDeviceModel.unload()
                    }
                }
        }
    }
}
