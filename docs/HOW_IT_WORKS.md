# How DS3Bridge works

This document explains why the DualShock 3 no longer works over Bluetooth on modern macOS, what was tried, and why DS3Bridge is built the way it is. All findings come from testing on macOS 26.7.1 (Apple Silicon) with the system logs (`log show --predicate 'process == "bluetoothd"'`).

## 1. The DualShock 3 never really pairs

The DS3 has no Bluetooth pairing of its own. Instead, over USB the host writes its own Bluetooth address into the controller (HID feature report `0xF5`). When you press PS, the controller **pages that address** and opens the two HID L2CAP channels, PSM `0x11` (control) and `0x13` (interrupt), **without any authentication or link key**. The PS3 simply accepted that.

Once connected, the host must send `SET_REPORT Feature 0xF4` with `42 03 00 00` (over USB it is `42 0C 00 00`) or the controller sends nothing. Input arrives on the interrupt channel as `A1 01 …` (49-byte report 0x01). LEDs and rumble are an output report 0x01 sent on the **control** channel (`52 01 …`).

## 2. Why macOS 12+ rejects it

What `bluetoothd` logs when the DS3 connects:

```
RecvConnectReq psm=17 addr=…                     ← the DS3 opens the HID control channel
Received incoming connection attempt from HID device
Device … running UUID 0x1124 has security level 2 and enforcing
Deferred security enforcement with linkKeyExists 0, remoteSupportsSSP 0
Send authentication request
Received a new pincode request                   ← the "enter a code" window
Reached pairing timeout … rejecting pairing request
Incoming connection security failed
```

macOS requires **security level 2 (authenticated link)** for every classic HID device. With no link key and no Secure Simple Pairing, the only option is legacy PIN pairing, which the DS3 cannot do. Entering `0000` does not help, because the controller never answers the authentication.

## 3. What does not work from user space

| Attempt | Result |
|---|---|
| Listening on PSM 0x11/0x13 with `IOBluetoothL2CAPChannel registerForChannelOpenNotifications` | Never fires: `bluetoothd`'s HID server takes those PSMs first and enforces the policy. |
| Opening the HID channels from the Mac (`openL2CAPChannelAsync`) while the DS3's ACL link is up | On macOS 26, IOBluetooth is a shim over `bluetoothd`: the call becomes a normal "connect services" request and gets the same security enforcement. |
| Pretending to be a DualShock 4 | The rejection happens before the device identity matters, and the identity comes from the controller's firmware. |
| Kernel extension / DriverKit | Requires disabling security or Apple-approved entitlements. DriverKit has no classic Bluetooth transport. |
| Virtual HID gamepad (CoreHID `HIDVirtualDevice`) | Needs the `com.apple.developer.hid.virtual.device` entitlement, granted by Apple on request. |

## 4. The solution: a second adapter with our own stack

On Apple Silicon, macOS only uses the built-in Bluetooth controller. A USB Bluetooth dongle is left unclaimed, so a user-space program can open it with **libusb** and run a complete Bluetooth host stack: [BTstack](https://github.com/bluekitchen/btstack), port `libusb`.

`ds3host` configures BTstack like the PS3:

- security mode 2, level 0, SSP disabled: no authentication is ever requested;
- L2CAP services for PSM `0x11` and `0x13` with `LEVEL_0`;
- connectable and not discoverable.

The DS3 is then "paired" over USB by writing the **adapter's** address into it (`ds3bt pair`). When you press PS it connects to the adapter, `ds3host` accepts both channels, sends `F4 42 03 00 00`, waits ~300 ms, and then sets the LED and a short rumble. If the output report arrives right after the enable, the controller answers `NOT_READY` and ignores it.

### Patches to BTstack (`patches/btstack/`)

- **No USB reset / no `set_configuration`** on the dongle. With an old ISSC adapter behind a USB-C hub, these calls triggered a **macOS kernel panic** (`Kernel data abort`, panicked task `ds3host`).
- **No BLE.** The tested adapter is Bluetooth 2.1. BTstack sent an LE command at startup, the adapter never answered, and the stack stalled: incoming connections then timed out (`status 0x10`). The build disables BLE (custom `btstack_config.h`, `stubs.c`, LE files excluded).
- **No HCI packet log by default.** BTstack's libusb port writes every Bluetooth packet to `/tmp/hci_dump.pklg`, which grows without limit. Now it is only written with `-l FILE`.

## 5. Reading the controller

Report 0x01 layout (byte 0 = report ID):

| Bytes | Content |
|---|---|
| 2 | Select, L3, R3, Start, Up, Right, Down, Left (bits) |
| 3 | L2, R2, L1, R1, Triangle, Circle, Cross, Square (bits) |
| 4 | PS (bit 0) |
| 6–9 | LX, LY, RX, RY (0–255, 128 = centre) |
| 14–25 | Pressure: Up, Right, Down, Left, L2, R2, L1, R1, Triangle, Circle, Cross, Square |
| 30 | Battery (`00`–`05`, `EE` charging, `EF` charged) |
| 41–48 | Accelerometer X/Y/Z and gyro Z, big-endian, ~512 = 0 |

On the test controller, the digital bits for the D-pad, L1/L2 and Triangle were reported as **pressed at rest**, with residual pressure values of 15–30. DS3Bridge therefore decides pressure-sensitive buttons from the analog value: pressed at ≥ 70, released below 50 (hysteresis). It only trusts the digital bits for Select, Start, L3, R3 and PS.

## 6. Getting the input to apps

### DSU (cemuhook)

`ds3host` serves the DSU protocol on `127.0.0.1:26760`: version, port info and pad data messages, CRC32 and a 5-second client subscription. Dolphin, Cemu and other emulators read it natively.

### Keyboard mode and the OpenEmu surprise

The first keyboard mode used `CGEventPost`. It worked everywhere and even let you *assign* buttons in OpenEmu's preferences, but **in-game OpenEmu ignored it**. OpenEmu-Silicon's `OEDeviceManager` reads keyboards in two ways:

- physical keyboards through **IOHID**, which is what gameplay uses;
- an `NSEvent` local monitor that ignores events whose `kCGEventSourceUnixProcessID` is 0, treating them as the physical keyboard. Events from other processes are forwarded with no device, and gameplay does not consume those.

So gameplay only reacts to a **HID keyboard device**. The solution is the signed and notarized [Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice) driver, the same one used by Karabiner-Elements. It provides a virtual HID keyboard that any app sees as real hardware. Its daemon only accepts root clients, so:

- `vhidkbd` runs as a root `launchd` service, from a root-owned path (`/usr/local/libexec/ds3bridge`);
- `ds3host` runs as the user and sends 3-byte datagrams `[usage lo, usage hi, down]` to a Unix socket `/var/run/ds3bridge.sock`, owned by that user with mode `0600`. Only that user can type through the virtual keyboard.

## 7. Files

| Path | Purpose |
|---|---|
| `src/ds3host/ds3host.c` | BTstack host, DS3 protocol, DSU server, keyboard mapping |
| `src/ds3host/kbd.c` | Keyboard output: Karabiner socket or `CGEvent` fallback |
| `src/vhidkbd/vhidkbd.cpp` | Root bridge to the Karabiner virtual keyboard |
| `src/ds3bt/ds3bt.m` | USB pairing (`pair`) and the IOBluetooth experiments (`listen`, `connect`) kept for reference |
| `patches/btstack/` | The three BTstack changes described above |
