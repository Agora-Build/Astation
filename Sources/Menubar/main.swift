import Cocoa
import Foundation

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