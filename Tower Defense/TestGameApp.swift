//
//  TestGameApp.swift
//  TestGame
//
//  Created by Zac on 4/10/26.
//

import SwiftUI

@main
struct TestGameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
