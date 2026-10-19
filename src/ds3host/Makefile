# Compila ds3host con BTstack (puerto libusb).
# No lo uses directamente: ejecuta ./build.sh en la raíz del repositorio, que
# descarga BTstack, aplica los parches y compila en build/ds3host.
BTSTACK_ROOT ?= ../../deps/btstack
include ${BTSTACK_ROOT}/port/libusb/Makefile

VPATH  += ${BTSTACK_ROOT}/port/libusb
CFLAGS += -I${BTSTACK_ROOT}/port/libusb -Wno-unused-parameter -Wno-unused-variable
# Sin BLE: fuera la base de datos LE y el Security Manager LE.
COMMON := $(filter-out le_device_db_tlv.c sm.c,$(COMMON))

.DEFAULT_GOAL := ds3host

ds3host: ${CORE_OBJ} ${COMMON_OBJ} ${CLASSIC_OBJ} ds3host.o stubs.o kbd.o
	${CC} $^ ${CFLAGS} ${LDFLAGS} -framework ApplicationServices -o $@

# El Makefile de BTstack define "clean_src" como "rm -rf *" en el directorio
# actual. Lo neutralizamos para no borrar nada por accidente.
clean_src:
	@echo "clean_src desactivado en DS3Bridge; usa ./build.sh --clean"
