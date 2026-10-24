# Builds ds3host with BTstack (libusb port).
# Do not use it directly: run ./build.sh at the repository root, which
# downloads BTstack, applies the patches and builds in build/ds3host.
BTSTACK_ROOT ?= ../../deps/btstack
include ${BTSTACK_ROOT}/port/libusb/Makefile

VPATH  += ${BTSTACK_ROOT}/port/libusb
CFLAGS += -I${BTSTACK_ROOT}/port/libusb -Wno-unused-parameter -Wno-unused-variable
# No BLE: leave out the LE device database and the LE Security Manager.
COMMON := $(filter-out le_device_db_tlv.c sm.c,$(COMMON))

.DEFAULT_GOAL := ds3host

ds3host: ${CORE_OBJ} ${COMMON_OBJ} ${CLASSIC_OBJ} ds3host.o stubs.o kbd.o
	${CC} $^ ${CFLAGS} ${LDFLAGS} -framework ApplicationServices -o $@

# BTstack's Makefile defines "clean_src" as "rm -rf *" in the current
# directory. Override it so nothing gets deleted by accident.
clean_src:
	@echo "clean_src is disabled in DS3Bridge; use ./build.sh --clean"
