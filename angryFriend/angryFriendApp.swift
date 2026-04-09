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
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Friend.self)
    }
}
