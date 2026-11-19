//
//  ExporterApp.swift
//  Exporter
//
//  Created by is52hertz on 2026/6/10.
//

import SwiftUI

@main
struct ExporterApp: App {
    @UIApplicationDelegateAdaptor(ExporterAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: appDelegate.model)
        }
    }
}

final class ExporterAppDelegate: NSObject, UIApplicationDelegate {
    let model = ExportModel()
    private var delivery: BackgroundDelivery?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let delivery = BackgroundDelivery(settings: model.settings, health: model.health)
        self.delivery = delivery
        delivery.start()
        return true
    }
}
