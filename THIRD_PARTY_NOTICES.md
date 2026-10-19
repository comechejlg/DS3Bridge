# Third-party notices

DS3Bridge does **not** bundle third-party source code in this repository. `build.sh` downloads the following projects at pinned commits. Their licenses apply to them and to anything built from them.

## BTstack — BlueKitchen GmbH

- https://github.com/bluekitchen/btstack (commit `e38553977a25fb0b55b383c72c289be0975f422c`)
- License: https://github.com/bluekitchen/btstack/blob/master/LICENSE. It is a BSD-style license **restricted to non-commercial use**. Commercial use requires a license from BlueKitchen (https://bluekitchen-gmbh.com).
- `patches/btstack/*.patch` are modifications of BTstack files (`port/libusb/main.c`, `platform/libusb/hci_transport_h2_libusb.c`) and are distributed under BTstack's license. `src/ds3host/btstack_config.h` is derived from BTstack's `port/libusb/btstack_config.h`.
- **Consequence:** the `ds3host` binary links BTstack, so it may only be used and distributed for non-commercial purposes.

## Karabiner-DriverKit-VirtualHIDDevice — Fumihiko Takayama / pqrs.org

- https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice (headers at commit `ac836ed8a974cd5182495251855cabdb762f50cb`; driver package v8.2.0)
- License: The Unlicense (public domain). Its bundled vendor libraries (asio, spdlog, nlohmann/json, etc.) keep their own licenses. See the `vendor/` directory of that repository.
- The driver itself is installed from the official signed and notarized package (Developer ID Fumihiko Takayama, team `G43BCU2T37`).

## ds3activate — vit9696

`src/ds3bt/ds3bt.m` is based on `ds3activate` (activation report `0xF4` and the output report layout):

```
Copyright (c) 2021 vit9696.  All Rights Reserved.
SPDX-License-Identifier: BSD-3-Clause

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Protocol references (no code copied)

- Linux kernel `drivers/hid/hid-sony.c`: DualShock 3 Bluetooth enable sequence and the output report layout.
- cemuhook / DSU protocol documentation: packet format of the DSU server.
