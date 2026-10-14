import Cocoa
import Foundation

if CommandLine.arguments.contains("--cloud-transcription-worker") {
    exit(CloudTranscriptionWorker.run())
}

if CommandLine.arguments.contains("--bundled-resources-check") {
    exit(TranscriptionValidation.checkBundledResources())
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

if !AgoraTokenService.isCompatible {
    Log.error("Incompatible token-library ABI. Token operations are unavailable; rebuild Astation.")
}

Log.info("Starting Astation - AI-powered work suite hub")
Log.info("App bundle: \(Bundle.main.bundleURL.path)")
Log.info("Atem E2E: verification and storage-key unlock; identity formats 1-\(AtemE2EIdentity.storedVersion)")

// Create and configure the application
let app = NSApplication.shared
let delegate = AstationApp()
app.delegate = delegate

// Set activation policy (status bar app, no dock icon)
app.setActivationPolicy(.accessory)

Log.info("Astation initialization complete")

// Run the application
app.run()
