import Cocoa
import Foundation

if CommandLine.arguments.contains("--cloud-transcription-worker") {
    exit(CloudTranscriptionWorker.run())
}

#if DEBUG
if CommandLine.arguments.contains("--transcription-check") {
    exit(TranscriptionValidation.run())
}
if CommandLine.arguments.contains("--audio-capture-check") {
    if #available(macOS 14.2, *) { exit(AudioCaptureValidation.run()) }
    print("Native app capture requires macOS 14.2 or later.")
    exit(1)
}
#endif

// Initialize file logging before anything else
// Logs: ~/Library/Logs/Astation/astation.log
Log.setup()

Log.info("Starting Astation - AI-powered work suite hub")

// Create and configure the application
let app = NSApplication.shared
let delegate = AstationApp()
app.delegate = delegate

// Set activation policy (status bar app, no dock icon)
app.setActivationPolicy(.accessory)

Log.info("Astation initialization complete")

// Run the application
app.run()
