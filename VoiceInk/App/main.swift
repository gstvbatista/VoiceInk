import Foundation

// Custom entry point: `VoiceInk transcribe ...` runs the headless CLI,
// anything else launches the regular SwiftUI app.
let launchArguments = CommandLine.arguments
if launchArguments.count > 1, launchArguments[1] == "transcribe" {
    TranscribeCommand.main(arguments: Array(launchArguments.dropFirst(2)))
} else {
    VoiceInkApp.main()
}
