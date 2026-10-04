import SwiftUI

struct ContentView: View {
    @StateObject private var display = DisplayManager.shared
    @StateObject private var state = DesktopState.shared

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: display.isConnected ? "display" : "display.trianglebadge.exclamationmark")
                .font(.system(size: 60))
                .foregroundStyle(display.isConnected ? .green : .secondary)

            Text(display.isConnected
                 ? "Connected (\(Int(display.size.width))×\(Int(display.size.height)))"
                 : "No external display")
                .font(.headline)

            HStack {
                Text("Connect wirelessly")
                AirPlayButton().frame(width: 44, height: 44)
            }

            Button("Add test window") {
                state.windows.append("Window \(state.windows.count + 1)")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
