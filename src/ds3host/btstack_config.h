//
// btstack_config.h — DS3Bridge (based on BTstack's port/libusb one).
// Classic Bluetooth only: no BLE, no SCO/audio (USB isochronous transfers),
// no mesh. This way it also works with old adapters (Bluetooth 2.x).
//

#ifndef BTSTACK_CONFIG_H
#define BTSTACK_CONFIG_H

// Port related features
#define HAVE_ASSERT
#define HAVE_BTSTACK_STDIN
#define HAVE_MALLOC
#define HAVE_POSIX_FILE_IO
#define HAVE_POSIX_TIME

// BTstack features that can be enabled
#define ENABLE_BTSTACK_STDIN_LOGGING
#define ENABLE_CLASSIC
#define ENABLE_LOG_ERROR
#define ENABLE_LOG_INFO
#define ENABLE_PRINTF_HEXDUMP
#define ENABLE_SDP_DES_DUMP
#define ENABLE_SOFTWARE_AES128

// BTstack configuration. buffers, sizes, ...
#define HCI_ACL_PAYLOAD_SIZE (1691 + 4)
#define HCI_INCOMING_PRE_BUFFER_SIZE 14 // sizeof BNEP header, avoid memcpy

#define NVM_NUM_DEVICE_DB_ENTRIES      16
#define NVM_NUM_LINK_KEYS              16

#endif
