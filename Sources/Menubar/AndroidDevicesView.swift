import SwiftUI
import AppKit

struct AndroidDevicesView: View {
    @ObservedObject var manager: AndroidDeviceManager
    @State private var showWireless = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Android Device Sharing").font(.title2).bold()
                    Spacer()
                    if manager.isBusy { ProgressView().controlSize(.small) }
                    Button("Retry") { manager.retry() }.disabled(manager.isBusy)
                }
                GroupBox("Remote Access") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Network address", selection: $manager.selectedAddressID) {
                            Text("Choose this Mac's IPv4 address").tag("")
                            if !manager.selectedAddressID.isEmpty && manager.selectedAddress == nil {
                                Text("Saved address unavailable").tag(manager.selectedAddressID)
                            }
                            ForEach(manager.addresses) { address in Text(address.label).tag(address.id) }
                        }.disabled(manager.isSharing || manager.isBusy)
                        HStack {
                            Text("Sharing port")
                            TextField("5038", text: $manager.portText)
                                .frame(width: 90)
                                .disabled(manager.isSharing || manager.isBusy)
                            Spacer()
                            Button(manager.isSharing ? "Stop Sharing" : "Start Sharing") {
                                if manager.isSharing { manager.stopSharing() } else { manager.startSharing() }
                            }.disabled(manager.isBusy || (!manager.isSharing && !manager.isReady))
                        }
                        Text("Sharing gives remote machines access to all devices and emulators on this Mac's ADB server, plus the local services exposed by forwarded ports. Allow only trusted machines to reach the sharing and forwarded ports through your VPN or firewall rules.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let endpoint = manager.endpoint {
                            Divider()
                            Text("Remote ADB server: \(endpoint)").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            HStack {
                                Button("Copy Address") { copy(endpoint) }
                                Button("Copy Shell Setup") { if let setup = manager.shellSetup { copy(setup) } }
                            }
                            Text("On your development machine, paste the shell setup, then run adb devices -l. This is a remote ADB server; do not use adb connect with this address.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else { Text("Sharing off").foregroundStyle(.secondary) }
                        if let error = manager.sharingError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }.padding(8)
                }
                GroupBox("Forwarded Ports (scrcpy)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Forward a port on the selected network address to a local port on this Mac. For scrcpy, start with shared port 27183 and local port 27183.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach($manager.portForwards) { $forward in
                            HStack {
                                Text("Shared port")
                                TextField("27183", text: $forward.sharedPort)
                                    .frame(width: 80)
                                    .accessibilityLabel("Shared port")
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text("Local port")
                                TextField("27183", text: $forward.localPort)
                                    .frame(width: 80)
                                    .accessibilityLabel("Local port on this Mac")
                                Spacer()
                                Button("Remove") { manager.removePortForward(id: forward.id) }
                            }.disabled(manager.isSharing || manager.isBusy)
                        }
                        Button("Add Port") { manager.addPortForward() }
                            .disabled(manager.isSharing || manager.isBusy || manager.portForwards.count >= AndroidForwardedPort.maximumCount)
                        if let address = manager.boundAddress {
                            ForEach(manager.boundForwardedPorts) { forward in
                                Text("\(address):\(forward.sharedPort) -> 127.0.0.1:\(forward.localPort)")
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        Text("Ports start and stop with sharing. After starting, copy a scrcpy command from your device below and run it on the remote computer. scrcpy creates the local ADB forward when it starts; no SSH tunnel is needed. Use a separate local port for each simultaneous scrcpy session.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                HStack {
                    Text("Devices on This Mac").font(.headline)
                    Spacer()
                    Button("Connect Wireless Phone...") { showWireless = true }
                        .disabled(manager.isBusy || !manager.isReady)
                }
                if let error = manager.deviceError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if manager.devices.isEmpty {
                    Text("Connect a phone by USB, enable USB debugging, and accept the authorization prompt on the phone. Already-connected wireless devices also appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(manager.devices) { device in
                    GroupBox {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.model).font(.headline)
                                Text("\(device.transport) - \(device.status)")
                                    .foregroundStyle(device.isAuthorized ? Color.secondary : Color.orange)
                                Text(device.serial).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 8) {
                                Button("Copy Device Command") {
                                    if let address = manager.boundAddress, let port = manager.boundPort {
                                        copy(AndroidCommands.deviceCommand(address: address, port: port, serial: device.serial))
                                    }
                                }.disabled(!manager.isSharing || !device.isAuthorized)
                                Menu("Copy scrcpy Command") {
                                    ForEach(manager.boundForwardedPorts) { forward in
                                        Button("Shared \(forward.sharedPort) / local \(forward.localPort)") {
                                            if let command = manager.scrcpyCommand(for: device, forward: forward) { copy(command) }
                                        }
                                    }
                                }.disabled(!manager.isSharing || manager.isBusy || !device.isAuthorized || manager.boundForwardedPorts.isEmpty)
                                    .help("Add a forwarded port and start sharing to copy a direct scrcpy command.")
                            }
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                HStack {
                    Text(manager.adbPath ?? "ADB not configured").font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Choose ADB...") { chooseADB() }.disabled(manager.isSharing || manager.isBusy)
                }
                if !manager.adbVersion.isEmpty {
                    Text(manager.adbVersion).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Use matching Platform-Tools across different machines. APK installation, shell, and logcat use the ADB connection directly. scrcpy uses a forwarded port as well. Reverse connections to services on the development machine still need a separate route or tunnel.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
        .onAppear { manager.startMonitoring() }
        .sheet(isPresented: $showWireless) { AndroidWirelessView(manager: manager) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func chooseADB() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose adb from your Android SDK platform-tools folder."
        if panel.runModal() == .OK, let url = panel.url { manager.chooseADB(url.path) }
    }
}

private struct AndroidWirelessView: View {
    @ObservedObject var manager: AndroidDeviceManager
    @Environment(\.dismiss) private var dismiss
    @State private var pairFirst = true
    @State private var pairingEndpoint = ""
    @State private var code = ""
    @State private var connectionEndpoint = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Wireless Phone").font(.title2).bold()
            Text("On Android 11 or later, enable Developer options > Wireless debugging. This Mac must be able to reach the phone's Wi-Fi address.")
            Toggle("Pair this phone first", isOn: $pairFirst)
            if pairFirst {
                Text("On the phone, select Pair device with pairing code.").font(.caption)
                TextField("Pairing IPv4:port", text: $pairingEndpoint)
                SecureField("Six-digit pairing code", text: $code)
            }
            Text("Use the IP address and port from the main Wireless debugging screen to connect. Its port can differ from the pairing port.").font(.caption)
            TextField("Debugging IPv4:port", text: $connectionEndpoint)
            if let message = manager.wirelessMessage { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Close") { code = ""; dismiss() }.disabled(manager.isBusy)
                Button(pairFirst ? "Pair & Connect" : "Connect") {
                    manager.connectWireless(pairingEndpoint: pairingEndpoint, code: code, connectionEndpoint: connectionEndpoint, pairFirst: pairFirst)
                    code = ""
                }.disabled(manager.isBusy)
            }
        }.padding(24).frame(width: 460)
            .disabled(manager.isBusy)
    }
}
