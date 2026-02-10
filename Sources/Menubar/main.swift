import Cocoa
import Foundation

print("🚀 Starting Astation - AI-powered work suite hub")

// Create and configure the application
let app = NSApplication.shared
let delegate = AstationApp()
app.delegate = delegate

// Set activation policy (status bar app, no dock icon)
app.setActivationPolicy(.accessory)

print("✅ Astation initialization complete")

// Run the application
app.run()