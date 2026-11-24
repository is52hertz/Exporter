//
//  ExporterApp.swift
//  Exporter
//
//  Created by is52hertz on 2026/6/10.
//

import SwiftUI
import UserNotifications

@main
struct ExporterApp: App {
    @UIApplicationDelegateAdaptor(ExporterAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: appDelegate.model)
        }
    }
}

final class ExporterAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = ExportModel()
    private var delivery: BackgroundDelivery?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        let delivery = BackgroundDelivery(settings: model.settings, health: model.health)
        self.delivery = delivery
        delivery.start()
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        switch notification.request.identifier {
        case BackgroundSendNotifications.successIdentifier:
            return [.list]
        case BackgroundSendNotifications.failureIdentifier:
            return [.banner, .list, .sound]
        default:
            return []
        }
    }
}
