import SwiftUI

@main
struct JarvisP1SApp: App {
    @StateObject private var app = JarvisAppModel()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
        }
    }
}
