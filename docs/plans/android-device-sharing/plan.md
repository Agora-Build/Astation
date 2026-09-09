# Android Device Sharing in Astation

Date: 2026-09-08  
Status: Implemented for local validation after approval; physical phone/NetBird and IDE validation remain pending.

## Implementation status

The Connections window now has an Android Devices tab with device detection,
authorization status, a saved configurable sharing port (default 5038), explicit
interface selection, Start/Stop Sharing, copyable commands, and Android wireless
pairing/connection. Sharing uses an Astation-owned NIO TCP listener and preserves
the local ADB server on stop. It starts off after relaunch and stops when the
selected network address disappears.

Device and sharing UI state are coordinated in one `AndroidDeviceManager` rather
than separate device/sharing manager classes. The Connections window controller
wraps the existing client view in tabs; the client list implementation is unchanged.

Automated validation covers device parsing, port persistence, command timeouts and
cancellation, output bounds, literal command arguments, concurrent 2 MB transfers,
half-close data integrity, listener stop/restart, occupied ports, backend version
queries, missing backends, and network-address loss. Existing Connections tests
and the C++ core tests pass. See README for the implemented setup flow.

The initial real A/B proof could not run in this workspace: no ADB installation or
phone was available, and there is no execution connection to machine A. USB/Wi-Fi
hardware checks and Android Studio/debugger routing remain explicit acceptance
work, not verified capabilities. No Android sharing listener was enabled on a real
network interface during implementation; automated tests use loopback fixtures.

## What we are building

Build an Android application on development machine A, then use a phone attached
to Mac B to install, run, inspect, and eventually debug that application. Astation
runs on B. A can already reach B through NetBird; Astation does not need to locate
A or manage the NetBird network.

The phone can connect to B by USB or Android wireless debugging. Astation displays
the phone and a remote ADB server address using **B's NetBird IP and a port**.

## Proposed architecture

```text
Machine A                           Mac B
                                    Astation
Build APK                           Android Devices UI
ADB client -- NetBird TCP ---------> Sharing listener on B_NETBIRD_IP:5038
                                             |
                                             v
                                    Local ADB server on 127.0.0.1:5037
                                             |
                                      +------+------+
                                      |             |
                                     USB       Wireless ADB
                                      |             |
                                      +------v------+
                                         Android phone
```

Use the standard ADB client/server protocol. Astation adds a TCP proxy from a
selected local interface to B's existing loopback ADB server. It forwards bytes
in both directions and does not implement Android's device protocol.

The proposed sharing port is **5038**, configurable if occupied. Port **5037**
remains B's local ADB server port. Earlier discussion used 5037 for the public
endpoint; separating these ports lets Astation own sharing without restarting or
rebinding the ADB server used by local development tools.

One endpoint exposes the server's entire device list, including emulators. Device
selection uses an ADB serial. A device row does not imply per-device access
control. The first version must say that sharing applies to all devices on B's
ADB server and use one global Start/Stop Sharing control.

## What works first, and what needs a separate proof

| Capability on A | Plan |
| --- | --- |
| List devices on B | First milestone |
| Install APK built on A | First milestone; APK bytes travel through B |
| Run shell commands, launch app, read logcat | First milestone |
| Push/pull files | Validate with the initial integration test |
| Use a phone already connected wirelessly to B | Same sharing path |
| Pair a wireless phone from Astation | Follow-up milestone in this plan |
| Android Studio device discovery and Run | Separate compatibility validation |
| Attach debugger / JDWP / framework dev-server ports | Separate port-routing validation |

Remote ADB does not automatically make every debugging port local to A.
`adb forward` creates its listening socket on **B**, where the ADB server runs.
Likewise, the host side of `adb reverse` is B. Debugger and development-server
workflows can therefore need additional tunnels or explicit routes. Do not claim
full Android Studio support based only on a successful APK install.

## User experience on B

Add an **Android Devices** tab to the current Connections window. Keep the
existing Clients & Agents content as its other tab; title the overall window
**Connections**. This follows the current native SwiftUI UI.

```text
Connections
[Clients & Agents]  [Android Devices]

Android Device Sharing
Network address:  100.x.x.x          [Choose Interface]
Sharing port:    5038
Status:          Sharing off        [Start Sharing]

Devices available through this ADB server
Pixel 9          USB       Authorized
Serial: ABC123

[Copy Device Command]

When sharing is running:
Remote ADB server: 100.x.x.x:5038
[Copy Address]  [Copy Shell Setup]  [Stop Sharing]
```

- Detect phones automatically once a usable local ADB server is available.
- Show `Unauthorized` with instructions to unlock the phone and accept USB
  debugging authorization; show `Offline` separately from disconnected.
- Show model, serial, and known transport. Preserve distinct ADB transports when
  the same physical phone is connected by both USB and Wi-Fi; do not deduplicate
  by model name or assume serials remain unchanged after switching transports.
- Show sharing health independently from device state. A listener can be running
  with zero phones connected.
- Enable Copy Address only after the listener is bound and its backend is healthy.
  Local readiness does not claim that A has passed a remote connectivity test.
- Start sharing only after the user enables it. Save interface and port choices,
  but leave sharing off after app relaunch in the first version.

## Commands generated for A

The UI inserts B's selected numeric IPv4 address and actual bound port. The
following placeholders are for this document only.

```bash
# Set this in the terminal session on A that will run adb.
export ADB_SERVER_SOCKET=tcp:<B_NETBIRD_IP>:5038

adb devices -l
adb -s <DEVICE_SERIAL> install -r ./app-debug.apk
adb -s <DEVICE_SERIAL> shell am start -n <PACKAGE>/<ACTIVITY>
adb -s <DEVICE_SERIAL> logcat

# Restore the default ADB server for this shell.
unset ADB_SERVER_SOCKET
```

Also offer a one-command form that does not modify the shell environment:

```bash
adb -H <B_NETBIRD_IP> -P 5038 devices -l
```

This address is an **ADB server endpoint**. `adb connect <B_IP>:5038` is not the
correct command: `adb connect` expects a device-side ADB endpoint.

## Implementation components

All feature code belongs in `Sources/Menubar`; use existing SwiftNIO dependencies.

| File | Responsibility |
| --- | --- |
| `ADBClient.swift` (new) | Resolve executable, run bounded commands asynchronously, parse device output, report version and errors |
| `AndroidDevice.swift` (new) | Device identity, transport, authorization state, model metadata |
| `AndroidDeviceManager.swift` (new) | Observable device list, polling, pairing/connection lifecycle, cancellation |
| `AndroidSharingServer.swift` (new) | NIO TCP listener, loopback backend connections, bounded buffers, backpressure, shutdown |
| `AndroidSharingManager.swift` (new) | Coordinate listener health, selected interface, port, configuration, UI state |
| `AndroidNetworkInterfaces.swift` (new) | Enumerate assigned interface addresses, validate explicit selection, detect address loss |
| `AndroidDevicesView.swift` (new) | Native SwiftUI device list, sharing controls, copy actions, wireless pairing sheet |
| `ConnectionsView.swift` | Add the Android Devices tab around existing client/agent content |
| `ConnectionsWindowController.swift` | Inject managers and update window title/sizing |
| `StatusBarController.swift` | Pass app-owned managers to the Connections window |
| `AstationApp.swift` | Own managers, initialize them, stop monitors and sharing at quit |
| `Tests/AstationTests/Android*Tests.swift` (new) | Command parsing, state, network selection, and TCP integration coverage |

No new Astation/Atem WebSocket messages, relay-server features, or changes on A
are required for the first command-line workflow beyond A having compatible ADB.

### ADB discovery and ownership

1. Prefer a saved, user-selected ADB executable. Otherwise check the usual Android
   SDK location (`~/Library/Android/sdk/platform-tools/adb`), SDK environment
   variables, Homebrew locations, and PATH. GUI launches may have a minimal PATH.
2. Require an executable and inspect its version. Show the chosen path/version in
   settings. Offer Choose ADB if missing; automatic SDK downloads are out of scope.
3. Explicitly target `127.0.0.1:5037` for B's commands; clear inherited remote ADB
   environment overrides. Pass arguments directly to `Process`, without a shell.
4. Reuse a compatible running server. If absent, start it normally on loopback.
   Probe server compatibility before invoking commands that might replace it.
   Surface mismatches instead of silently killing another tool's server.
5. Poll `adb devices -l` on a background task every two seconds for the initial
   version, without overlapping commands. Bound command runtime and output, and
   cancel promptly at shutdown. Streaming device tracking can follow if useful.
6. Cache device metadata and use explicit serial selection for enrichment. Never
   query unauthorized devices as if they were ready.
7. Stop Sharing closes the listener and all proxy connections; it leaves the
   local ADB server and its USB/wireless transports running.

Use matching Android SDK Platform-Tools versions on A and B during the proof.
An exposed ADB server also accepts server-level control commands from its clients;
trusted remote clients can disrupt that server, including via `kill-server`.
The initial proxy does not filter ADB commands or provide per-device isolation.

### Network selection and sharing lifecycle

- Enumerate local IPv4 addresses with interface names. Let the user select B's
  NetBird address, validated as currently assigned to this Mac. Do not assume
  an address in `100.64.0.0/10` or an interface named `utun` must belong to NetBird.
- Bind only the selected address, never wildcard `0.0.0.0`. Astation does not
  configure NetBird or open a router port. IPv6 can be a later extension.
- Persist the selected address/interface and requested port. Report an occupied
  port without killing its owner or silently advertising a different address.
- Use interface-specific address monitoring while sharing; the existing generic
  `NetworkMonitor` callback alone may miss a VPN change if internet stays up.
- On loss/change of the selected address, close sharing and active streams and
  require a fresh Start Sharing. Never fall back to a LAN interface.
- For each accepted socket, connect only to `127.0.0.1:5037`. Implement bidirectional
  forwarding with backpressure, bounded pending data, connection timeouts, correct
  EOF/half-close handling, and a bounded concurrent-connection count. Long-lived
  shell/logcat streams must not expire because a short command timeout elapsed.
- If the backend dies, mark sharing unavailable and close the listener/streams.
  Offer Retry; do not spin in an uncontrolled ADB restart loop.
- Sharing states: off, starting, running, stopping, unavailable/error. Keep device
  discovery errors separate so users can diagnose phone vs network problems.

NetBird supplies transport encryption and peer access policy. The raw ADB server
protocol has no client authentication. Limit the NetBird policy for this port to
trusted development peers. Astation's existing Atem pairing does not authenticate
clients of this separate TCP listener. This is a property of the chosen design,
not an additional Astation sign-in flow.

### Wireless debugging

Support phones already connected through wireless ADB immediately through normal
device discovery. Add a pairing sheet for Android 11+ wireless debugging:

1. On the phone, open Developer options > Wireless debugging > Pair using code.
2. Enter the phone's pairing IP/port and temporary pairing code in Astation.
3. B runs `adb pair <PHONE_PAIRING_IP>:<PAIRING_PORT>` and supplies the code through
   the process input. Never persist the code or include it in logs.
4. Enter the phone's debugging IP/port and run `adb connect` from B. Pairing and
   connection ports can differ; show separate fields and instructions.
5. Confirm an authorized device appears in B's ADB device list.

B must be able to reach the phone's Wi-Fi address. A does not need that route.
Turning off Wi-Fi, restarting the phone, or changing wireless debugging ports can
require reconnecting. Show the real state and allow updating the address; do not
promise seamless USB-to-Wi-Fi switching. QR pairing, automatic mDNS discovery,
legacy `adb tcpip 5555`, and persistent retry policies are later enhancements.

## Build sequence and exit criteria

### 1. Prove the remote ADB path

With the actual A/B setup available, validate the architecture with
a temporary forwarding listener scoped to B's NetBird address. Do not enable
sharing without a selected interface and an explicit Start Sharing action.

Exit criteria: A lists an authorized USB phone on B, installs an APK built on A,
launches the app, streams logcat, and transfers a file successfully. Record A/B
Platform-Tools versions, selected addresses, port, and command results. This
requires execution access on A or the user running the generated commands there.

### 2. Add device discovery and status UI

Implement ADB discovery, safe process management, parsing, observable state, and
the Android Devices tab. Verify authorization prompts, plug/unplug, offline state,
multiple transports, and a missing ADB installation.

Exit criteria: the phone's actual state is visible and updates without blocking
the menubar UI or disrupting existing local ADB sessions.

### 3. Add controlled remote sharing

Implement interface selection, the TCP proxy, explicit Start/Stop, error handling,
and commands containing the selected B address, actual port, and device serial.

Exit criteria: repeat milestone 1 using Astation, verify Stop interrupts existing
streams, verify only the selected address listens, and verify app quit, VPN loss,
backend failure, and port collision behavior.

### 4. Add wireless pairing and connection

Implement the two-endpoint pairing flow and surface actionable errors. Validate
wireless-only use after unplugging USB, and demonstrate A still uses B's same
sharing address with the newly selected device serial.

Exit criteria: A installs and reads logs over B's wireless phone transport; pairing
codes are absent from persisted settings and application logs.

### 5. Validate development-tool integration separately

Test the actual Android Studio version on A for remote server selection, device
discovery, installation, launch, and breakpoint attachment. Test any framework
development-server workflow in use. Document which operations require additional
port forwarding and propose those routes before adding them.

Exit criteria: a concrete supported-tools matrix. Full IDE debugging is not a
release promise until a breakpoint can be hit from A on the phone attached to B.

### 6. Finish validation and documentation

Run the focused Swift tests, existing Connections tests, and the repository's
required build checks with the C++ core/Agora SDK dependencies available. Document
setup, matching ADB versions, NetBird access, command examples, and troubleshooting
in README. Record any unavailable hardware checks explicitly.

## Test coverage

| Area | Evidence required |
| --- | --- |
| Device parsing | Empty list, USB, wireless, emulator, unauthorized, offline, malformed/extra fields, duplicate physical phone transports |
| Process handling | Timeout, missing executable, cancellation, large output, nonzero exit, sanitized environment and pairing code handling |
| Interface selection | Correct bind address, no wildcard fallback, address disappears/changes, port conflict |
| TCP forwarding | Multi-megabyte integrity, simultaneous streams, slow consumer, half-close, backend refusal, abrupt disconnect, complete shutdown |
| UI/state | Listener health vs device authorization, no ready command on failure, safe shell quoting, serial changes |
| Real A-to-B workflow | APK install/launch, logcat, push/pull over NetBird for USB and wireless |
| Lifecycle | Stop/quit ends remote streams while preserving local ADB; relaunch starts with sharing off |
| Regression | Existing Clients & Agents selection, pinning, and remote-control actions still work |

## Decisions proposed for review

1. Use B's NetBird IPv4 address with configurable sharing port 5038.
2. Share B's existing ADB server through an Astation-owned TCP proxy.
3. Use one global sharing control; all devices on that ADB server are accessible.
4. Deliver USB plus command-line install/log workflows first, then wireless pairing.
5. Validate Android Studio/debugger port routing as a separate milestone.
6. Keep sharing off by default and after relaunch; preserve local ADB on stop/quit.

## Review artifact

This document records the implementation plan and validation status. Serve only this dedicated directory
through Atem, so the review server exposes the plan without unrelated repo files:

```bash
atem serv files docs/plans/android-device-sharing --background --no-browser
```

Atem renders Markdown for browser review. Its file server uses HTTPS with a
self-signed certificate. This review server is separate from the proposed Android
sharing listener and does not enable access to any Android device.
