import SwiftUI
import UIKit

@main
struct RelayCodeApp: App {
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
