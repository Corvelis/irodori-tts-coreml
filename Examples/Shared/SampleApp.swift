import SwiftUI

@main struct IrodoriSampleApp: App {
    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            ContentView().frame(minWidth: 740, minHeight: 680)
            #else
            NavigationStack {
                ContentView().toolbar(.hidden, for: .navigationBar)
            }
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1060, height: 780)
        #endif
    }
}
