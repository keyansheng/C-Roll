import SwiftUI

@main
struct GateApp: App {
    @StateObject private var camera = CameraController()
    var body: some Scene {
        WindowGroup {
            CameraView(camera: camera)
                .preferredColorScheme(.dark)
        }
    }
}
