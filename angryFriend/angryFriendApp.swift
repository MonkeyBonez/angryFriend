//
//  angryFriendApp.swift
//  angryFriend
//
//  Created by Snehal Mulchandani on 3/9/26.
//

import SwiftUI
import SwiftData

@main
struct angryFriendApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Shared so the background scan can reach the store when iOS launches the
    /// app with no UI (an overnight run).
    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: Friend.self, ScanState.self)
        } catch {
            fatalError("Couldn't open the friends store: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(Self.container)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FriendRescanner.registerBackgroundTask()
        return true
    }
}
