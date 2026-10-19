// kbd.c — salida de teclado del mando.
//
// Dos modos:
//  * Teclado virtual HID (Karabiner) — si existe el socket de vhidkbd (servicio del
//    sistema). Las teclas se mandan a vhidkbd (root) por ese socket Unix, que las convierte en un
//    teclado HID "real". Necesario para OpenEmu-Silicon, que en partida solo lee
//    teclados HID y descarta las pulsaciones sintéticas.
//  * Teclas sintéticas (CGEvent) — por defecto. Valen para la mayoría de apps.
//    Requiere permiso de Accesibilidad para la app que lanza el programa.
#include <ApplicationServices/ApplicationServices.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "kbd.h"

static CGEventSourceRef src;
static bool use_vhid = false;
static int vhid_fd = -1;
static struct sockaddr_un vhid_addr;
#define VHID_SOCK "/var/run/ds3bridge.sock"

// Tecla virtual de macOS (kVK_*) -> uso HID de teclado (página 0x07).
static uint16_t mac_to_hid(unsigned short k) {
  switch (k) {
    case 0x00: return 0x04; /* A */   case 0x01: return 0x16; /* S */
    case 0x02: return 0x07; /* D */   case 0x03: return 0x09; /* F */
    case 0x04: return 0x0B; /* H */   case 0x06: return 0x1D; /* Z */
    case 0x07: return 0x1B; /* X */   case 0x08: return 0x06; /* C */
    case 0x09: return 0x19; /* V */   case 0x0C: return 0x14; /* Q */
    case 0x0D: return 0x1A; /* W */   case 0x0E: return 0x08; /* E */
    case 0x12: return 0x1E; /* 1 */   case 0x14: return 0x20; /* 3 */
    case 0x22: return 0x0C; /* I */   case 0x25: return 0x0F; /* L */
    case 0x26: return 0x0D; /* J */   case 0x28: return 0x0E; /* K */
    case 0x2D: return 0x11; /* N */   case 0x2E: return 0x10; /* M */
    case 0x24: return 0x28; /* Intro */
    case 0x7B: return 0x50; /* Izq */ case 0x7C: return 0x4F; /* Der */
    case 0x7D: return 0x51; /* Abajo */ case 0x7E: return 0x52; /* Arriba */
    default: return 0;
  }
}

bool kbd_init(bool prompt) {
  const char *v = getenv("DS3_NO_VHID");
  if (!(v && strcmp(v, "1") == 0) && access(VHID_SOCK, W_OK) == 0) {
    use_vhid = true;
    vhid_fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    memset(&vhid_addr, 0, sizeof vhid_addr);
    vhid_addr.sun_family = AF_UNIX;
    strlcpy(vhid_addr.sun_path, VHID_SOCK, sizeof vhid_addr.sun_path);
    return vhid_fd >= 0;
  }
  // OJO OpenEmu: descarta las teclas con "proceso origen" 0; marcamos nuestro PID.
  src = CGEventSourceCreate(kCGEventSourceStatePrivate);
  const void *k[] = { kAXTrustedCheckOptionPrompt };
  const void *vv[] = { prompt ? kCFBooleanTrue : kCFBooleanFalse };
  CFDictionaryRef o = CFDictionaryCreate(NULL, k, vv, 1, &kCFTypeDictionaryKeyCallBacks,
                                         &kCFTypeDictionaryValueCallBacks);
  bool ok = AXIsProcessTrustedWithOptions(o);
  CFRelease(o);
  return ok;
}

bool kbd_is_vhid(void) { return use_vhid; }

bool kbd_trusted(void) { return use_vhid || AXIsProcessTrusted(); }

void kbd_key(unsigned short code, bool down) {
  if (use_vhid) {
    uint16_t u = mac_to_hid(code);
    if (!u) return;
    uint8_t msg[3] = { (uint8_t)(u & 0xFF), (uint8_t)(u >> 8), down ? 1 : 0 };
    sendto(vhid_fd, msg, sizeof msg, 0, (struct sockaddr *)&vhid_addr, sizeof vhid_addr);
    return;
  }
  CGEventRef e = CGEventCreateKeyboardEvent(src, (CGKeyCode)code, down);
  if (!e) return;
  CGEventSetFlags(e, 0);
  CGEventSetIntegerValueField(e, kCGEventSourceUnixProcessID, getpid());
  CGEventPost(kCGSessionEventTap, e);
  CFRelease(e);
}
