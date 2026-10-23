# Troubleshooting / Problemas

**`build.sh` says libusb is missing** — `brew install libusb pkg-config`.

**`ds3host` does not print "Adaptador listo"** (adapter ready)
- Check that macOS sees the adapter: `ioreg -p IOUSB -l -w0 | grep -E '"USB Product Name"|bDeviceClass'`. A Bluetooth dongle usually has `bDeviceClass = 224`. If it doesn't appear at all, try another port or USB adapter.
- Only one program can use the adapter at a time. Close other `ds3host` windows.
- If you see repeated `status 0x10` connection failures, the adapter may not support a command BTstack sent. Run `bin/ds3host -l /tmp/ds3.pklg`, reproduce the problem and open an issue with the log. The log contains your devices' Bluetooth addresses, so review it before sharing.

**Pressing PS does nothing / LEDs keep blinking**
- Pair again with the cable (`scripts/Pair controller (USB cable).command`). Using the controller with a PS3 or the Mac's own Bluetooth overwrites the stored address.
- Make sure `ds3host` is running *before* you press PS. The controller only tries for a few seconds.

**macOS shows a "connection request / enter a code" window**
- That is the Mac's *built-in* Bluetooth: the controller is still paired to the Mac instead of the adapter. Pair again with the script. You can cancel the window.

**Buttons register in OpenEmu's preferences but not in-game**
- The Karabiner service is not active. Check that `/var/run/ds3bridge.sock` exists and look at `/var/log/ds3bridge-vhidkbd.log`, which should end with `teclado virtual LISTO` (virtual keyboard ready). Re-run `scripts/Install service.command` if needed.
- The driver must be enabled in *System Settings → General → Login Items & Extensions → Driver Extensions*. `systemextensionsctl list` should show `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice … [activated enabled]`.

**The controller types into other apps** — press **PS** to pause keyboard mode (LED 4).

**A button is "stuck" or ghost presses appear** — the thresholds are `PRESS_ON 70` / `PRESS_OFF 50` in `src/ds3host/ds3host.c`. Tune them for your controller and rebuild.

**The Mac froze or rebooted while using DS3Bridge** — this has not happened with the shipped patches, but if it does with your adapter, please open an issue with its vendor/product ID and your macOS version.
