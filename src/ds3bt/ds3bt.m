//
// ds3bt.m — DualShock 3 por Bluetooth en macOS, en espacio de usuario.
//
// macOS 12+ rechaza el DS3 como HID porque el mando no hace "bonding".
// Este programa escucha él mismo los canales L2CAP HID (PSM 0x11 control,
// 0x13 interrupción), activa el mando y lee sus reports.
//
// Basado en ds3activate (c) 2021 vit9696, BSD-3-Clause, y en el protocolo
// documentado por el driver hid-sony de Linux.
//
// Compilar:  ./build.sh
//
// Uso:
//   ./ds3bt pair            (por USB) graba la MAC Bluetooth de este Mac en el mando
//   ./ds3bt listen          espera al mando por Bluetooth (pulsa PS) y muestra lo que llega
//   ./ds3bt connect <MAC>   intenta abrir la conexión desde el Mac (plan B)
//

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <IOKit/hid/IOHIDLib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const SInt32 kSonyVendorId = 0x054C;
static const SInt32 kDS3ProductId = 0x0268;

#define PSM_CTRL 0x11
#define PSM_INTR 0x13

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
  NSDateFormatter *df = nil;
  static dispatch_once_t once;
  static NSDateFormatter *shared;
  dispatch_once(&once, ^{ shared = [NSDateFormatter new]; shared.dateFormat = @"HH:mm:ss.SSS"; });
  df = shared;
  printf("[%s] ", [[df stringFromDate:[NSDate date]] UTF8String]);
  va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
  printf("\n");
  fflush(stdout);
}

static void hexline(const char *label, const uint8_t *b, size_t n) {
  printf("    %s (%zu):", label, n);
  for (size_t i = 0; i < n && i < 64; i++) printf(" %02X", b[i]);
  printf("\n");
  fflush(stdout);
}

static bool parse_mac(const char *s, uint8_t out[6]) {
  int v[6];
  if (sscanf(s, "%x:%x:%x:%x:%x:%x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6 &&
      sscanf(s, "%x-%x-%x-%x-%x-%x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6)
    return false;
  for (int i = 0; i < 6; i++) { if (v[i] < 0 || v[i] > 255) return false; out[i] = (uint8_t)v[i]; }
  return true;
}

// ---------------------------------------------------------------------------
// Estado del mando (parseo del input report 0x01, mismo formato USB y BT)
// ---------------------------------------------------------------------------

typedef struct {
  uint32_t buttons;            // bitmask, ver kButtonNames
  uint8_t  lx, ly, rx, ry;     // 0..255, 128 = centro
  uint8_t  l2, r2;             // gatillos analógicos
  uint8_t  pressure[12];       // up right down left L2 R2 L1 R1 tri circ cross square
  int16_t  accel[3];           // crudo, ~512 = 0g, ~113 por g
  int16_t  gyro;               // crudo, eje Z (yaw)
  uint8_t  battery;            // 0x00..0x05, 0xEE cargando, 0xEF cargado
} DS3State;

static const char *kButtonNames[17] = {
  "SELECT", "L3", "R3", "START", "UP", "RIGHT", "DOWN", "LEFT",
  "L2", "R2", "L1", "R1", "TRIANGLE", "CIRCLE", "CROSS", "SQUARE", "PS"
};

// r apunta al byte del report ID (0x01).
static bool ds3_parse(const uint8_t *r, size_t n, DS3State *s) {
  if (n < 49 || r[0] != 0x01) return false;
  s->buttons = (uint32_t)r[2] | ((uint32_t)r[3] << 8) | ((uint32_t)(r[4] & 0x01) << 16);
  s->lx = r[6]; s->ly = r[7]; s->rx = r[8]; s->ry = r[9];
  memcpy(s->pressure, r + 14, 12);
  s->l2 = r[18]; s->r2 = r[19];
  s->battery = r[30];
  s->accel[0] = (int16_t)((r[41] << 8) | r[42]);
  s->accel[1] = (int16_t)((r[43] << 8) | r[44]);
  s->accel[2] = (int16_t)((r[45] << 8) | r[46]);
  s->gyro     = (int16_t)((r[47] << 8) | r[48]);
  return true;
}

static void ds3_print(const DS3State *s) {
  char btn[160] = "";
  for (int i = 0; i < 17; i++) {
    if (s->buttons & (1u << i)) { strlcat(btn, kButtonNames[i], sizeof btn); strlcat(btn, " ", sizeof btn); }
  }
  printf("\r  L(%3u,%3u) R(%3u,%3u) L2=%3u R2=%3u acc(%4d,%4d,%4d) gyro=%4d bat=%02X  %-48s",
         s->lx, s->ly, s->rx, s->ry, s->l2, s->r2,
         s->accel[0], s->accel[1], s->accel[2], s->gyro, s->battery, btn);
  fflush(stdout);
}

// Report de salida 0x01 (LEDs + vibración). Mismo contenido que por USB.
// 36 bytes = sizeof(struct sixaxis_output_report) en hid-sony.
static void ds3_build_output(uint8_t out[36], uint8_t ledMask, uint8_t rumbleWeak, uint8_t rumbleStrong) {
  static const uint8_t base[36] = {
    0x01,
    0x00, 0x00, 0x00, 0x00, 0x00,       // rumble: pad, dur_der, on_der, dur_izq, fuerza_izq
    0x00, 0x00, 0x00, 0x00,             // padding
    0x00,                               // bitmap LEDs: 0x02=LED1 .. 0x10=LED4
    0xFF, 0x27, 0x10, 0x00, 0x32,       // LED 4
    0xFF, 0x27, 0x10, 0x00, 0x32,       // LED 3
    0xFF, 0x27, 0x10, 0x00, 0x32,       // LED 2
    0xFF, 0x27, 0x10, 0x00, 0x32,       // LED 1
    0x00, 0x00, 0x00, 0x00, 0x00,
  };
  memcpy(out, base, 36);
  if (rumbleWeak)   { out[2] = 0xFE; out[3] = 1; }
  if (rumbleStrong) { out[4] = 0xFE; out[5] = rumbleStrong; }
  out[10] = ledMask;
}

// ---------------------------------------------------------------------------
// Sesión Bluetooth con un mando
// ---------------------------------------------------------------------------

@interface DS3Session : NSObject <IOBluetoothL2CAPChannelDelegate>
@property (nonatomic, strong) IOBluetoothDevice *device;
@property (nonatomic, strong) IOBluetoothL2CAPChannel *ctrl;
@property (nonatomic, strong) IOBluetoothL2CAPChannel *intr;
@property (nonatomic) BOOL activated;
@property (nonatomic) BOOL ctrlOpen, intrOpen;
@property (nonatomic) unsigned long reports;
@end

@implementation DS3Session

- (void)attach:(IOBluetoothL2CAPChannel *)ch {
  ch.delegate = self;
  if (ch.PSM == PSM_CTRL) self.ctrl = ch;
  if (ch.PSM == PSM_INTR) self.intr = ch;
  // Los canales entrantes ya llegan abiertos; los salientes avisan en OpenComplete.
  if (ch.isIncoming && self.ctrl && self.intr && !self.activated)
    [self performSelector:@selector(activate) withObject:nil afterDelay:0.1];
}

- (void)sendCtrl:(const uint8_t *)b length:(size_t)n what:(const char *)what {
  if (!self.ctrl) return;
  IOReturn r = [self.ctrl writeSync:(void *)b length:(UInt16)n];
  logf_("-> control: %s (IOReturn 0x%08X)", what, r);
}

- (void)activate {
  if (self.activated) return;
  self.activated = YES;
  // SET_REPORT | Feature, report 0xF4: modo operativo por Bluetooth (42 03 00 00).
  const uint8_t enable[] = { 0x53, 0xF4, 0x42, 0x03, 0x00, 0x00 };
  [self sendCtrl:enable length:sizeof enable what:"SET_REPORT F4 (activar)"];

  // SET_REPORT | Output, report 0x01: LED1 encendido + vibración corta.
  uint8_t pkt[37]; pkt[0] = 0x52;
  ds3_build_output(pkt + 1, 0x02, 1, 0xFF);
  [self sendCtrl:pkt length:sizeof pkt what:"SET_REPORT 01 (LED1 + vibracion)"];

  // Y a los 600 ms paramos la vibración dejando el LED.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    uint8_t p2[37]; p2[0] = 0x52;
    ds3_build_output(p2 + 1, 0x02, 0, 0);
    [self sendCtrl:p2 length:sizeof p2 what:"SET_REPORT 01 (LED1, sin vibracion)"];
  });
}

- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)ch data:(void *)data length:(size_t)len {
  const uint8_t *b = data;
  if (ch.PSM == PSM_INTR && len >= 2 && b[0] == 0xA1 && b[1] == 0x01) {
    DS3State s;
    if (ds3_parse(b + 1, len - 1, &s)) {
      if (self.reports++ == 0) { printf("\n"); logf_("¡Llegan input reports! Mueve el mando (Ctrl-C para salir)"); }
      ds3_print(&s);
    }
    return;
  }
  printf("\n");
  logf_("<- %s", ch.PSM == PSM_CTRL ? "control" : "interrupcion");
  hexline("datos", b, len);
}

- (void)l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)ch status:(IOReturn)error {
  logf_("canal PSM 0x%02X abierto (status 0x%08X)", ch.PSM, error);
  if (error != kIOReturnSuccess) {
    if (ch == self.ctrl) self.ctrl = nil;
    if (ch == self.intr) self.intr = nil;
    return;
  }
  if (ch.PSM == PSM_CTRL) self.ctrlOpen = YES;
  if (ch.PSM == PSM_INTR) self.intrOpen = YES;
  if (self.ctrlOpen && self.intrOpen && !self.activated)
    [self performSelector:@selector(activate) withObject:nil afterDelay:0.1];
}

- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel *)ch {
  printf("\n");
  logf_("canal PSM 0x%02X cerrado", ch.PSM);
  if (ch == self.ctrl) { self.ctrl = nil; self.ctrlOpen = NO; }
  if (ch == self.intr) { self.intr = nil; self.intrOpen = NO; }
  if (!self.ctrl && !self.intr) { self.activated = NO; self.reports = 0; }
}

@end

// ---------------------------------------------------------------------------
// Escucha de conexiones entrantes
// ---------------------------------------------------------------------------

@interface Listener : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, DS3Session *> *sessions;
@property (nonatomic, strong) NSMutableArray *notes;
@end

@implementation Listener

- (instancetype)init {
  if ((self = [super init])) { _sessions = [NSMutableDictionary new]; _notes = [NSMutableArray new]; }
  return self;
}

- (DS3Session *)sessionFor:(IOBluetoothDevice *)dev {
  NSString *k = dev.addressString ?: @"?";
  DS3Session *s = self.sessions[k];
  if (!s) { s = [DS3Session new]; s.device = dev; self.sessions[k] = s; }
  return s;
}

- (void)start {
  id n;
  n = [IOBluetoothDevice registerForConnectNotifications:self selector:@selector(connected:device:)];
  if (n) [self.notes addObject:n];
  logf_("notificación de conexiones ACL: %s", n ? "OK" : "FALLÓ");

  n = [IOBluetoothL2CAPChannel registerForChannelOpenNotifications:self
                                                           selector:@selector(channelOpened:channel:)
                                                            withPSM:PSM_CTRL
                                                          direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
  if (n) [self.notes addObject:n];
  logf_("escucha PSM 0x11 (HID control): %s", n ? "OK" : "FALLÓ");

  n = [IOBluetoothL2CAPChannel registerForChannelOpenNotifications:self
                                                           selector:@selector(channelOpened:channel:)
                                                            withPSM:PSM_INTR
                                                          direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
  if (n) [self.notes addObject:n];
  logf_("escucha PSM 0x13 (HID interrupción): %s", n ? "OK" : "FALLÓ");

  // Diagnóstico extra: cualquier canal L2CAP entrante, sea cual sea el PSM.
  n = [IOBluetoothL2CAPChannel registerForChannelOpenNotifications:self
                                                           selector:@selector(anyChannel:channel:)];
  if (n) [self.notes addObject:n];
}

- (void)connected:(IOBluetoothUserNotification *)note device:(IOBluetoothDevice *)dev {
  logf_("conexión ACL: %s \"%s\" (entrante=%d, CoD 0x%06X)",
        [dev.addressString UTF8String], [dev.name ?: @"(sin nombre)" UTF8String],
        dev.isIncoming, (unsigned)dev.classOfDevice);
  [dev registerForDisconnectNotification:self selector:@selector(disconnected:device:)];
}

- (void)disconnected:(IOBluetoothUserNotification *)note device:(IOBluetoothDevice *)dev {
  printf("\n");
  logf_("desconexión ACL: %s", [dev.addressString UTF8String]);
}

- (void)anyChannel:(IOBluetoothUserNotification *)note channel:(IOBluetoothL2CAPChannel *)ch {
  if (ch.PSM == PSM_CTRL || ch.PSM == PSM_INTR) return;
  logf_("(info) canal L2CAP PSM 0x%04X con %s", ch.PSM, [ch.device.addressString UTF8String]);
}

- (void)channelOpened:(IOBluetoothUserNotification *)note channel:(IOBluetoothL2CAPChannel *)ch {
  logf_("¡canal HID entrante! PSM 0x%02X desde %s \"%s\"", ch.PSM,
        [ch.device.addressString UTF8String], [ch.device.name ?: @"" UTF8String]);
  [[self sessionFor:ch.device] attach:ch];
}

// Plan C: el mando abre el enlace ACL y bluetoothd lo retiene ~35 s esperando
// un emparejamiento que nunca llega. Aprovechamos ese enlace para abrir NOSOTROS
// los canales 0x11/0x13 (salientes), que no pasan por el servidor HID del sistema.
- (void)watch:(NSString *)addr {
  IOBluetoothDevice *dev = [IOBluetoothDevice deviceWithAddressString:addr];
  if (!dev) { logf_("MAC no válida"); return; }
  logf_("vigilando el enlace de %s ...", [addr UTF8String]);
  __block BOOL wasUp = NO;
  __block BOOL busy = NO;
  __block IOReturn lastR = 1;
  __block int tick = 0;
  NSTimer *t = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
    // En macOS 26 el objeto IOBluetoothDevice no siempre se refresca: pedimos uno nuevo.
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:addr];
    BOOL up = d.isConnected || (d.connectionHandle != kBluetoothConnectionHandleNone && d.connectionHandle != 0);
    if (up && !wasUp) logf_("enlace ACL con el mando ARRIBA (handle 0x%04X)", d.connectionHandle);
    if (!up && wasUp) { printf("\n"); logf_("enlace ACL con el mando abajo"); }
    wasUp = up;
    DS3Session *s = [self sessionFor:dev];
    tick++;
    // Con enlace detectado: intentamos ya. Sin él: intentamos igualmente cada ~1 s
    // por si el aviso de conexión no nos llega (abrir un canal reutiliza el ACL si existe).
    if (!busy && !s.ctrl && (up || tick % 20 == 0)) {
      busy = YES;
      IOBluetoothL2CAPChannel *c = nil;
      IOReturn r = [d openL2CAPChannelAsync:&c withPSM:PSM_CTRL delegate:s];
      if (r != lastR || up) logf_("abrir PSM 0x11 saliente: 0x%08X%s", r, up ? " (con enlace)" : "");
      lastR = r;
      if (r == kIOReturnSuccess && c) {
        [s attach:c];
        IOBluetoothL2CAPChannel *i = nil;
        r = [d openL2CAPChannelAsync:&i withPSM:PSM_INTR delegate:s];
        logf_("abrir PSM 0x13 saliente: 0x%08X", r);
        if (r == kIOReturnSuccess && i) [s attach:i];
      }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ busy = NO; });
    }
  }];
  [[NSRunLoop currentRunLoop] addTimer:t forMode:NSDefaultRunLoopMode];
}

// Plan B: abrir nosotros los canales hacia el mando.
- (void)connectTo:(NSString *)addr {
  IOBluetoothDevice *dev = [IOBluetoothDevice deviceWithAddressString:addr];
  if (!dev) { logf_("MAC no válida"); return; }
  logf_("abriendo conexión con %s ...", [addr UTF8String]);
  IOReturn r = [dev openConnection];
  logf_("openConnection: 0x%08X", r);
  if (r != kIOReturnSuccess) return;
  DS3Session *s = [self sessionFor:dev];
  IOBluetoothL2CAPChannel *c = nil, *i = nil;
  r = [dev openL2CAPChannelSync:&c withPSM:PSM_CTRL delegate:s];
  logf_("abrir PSM 0x11: 0x%08X", r);
  if (r == kIOReturnSuccess) [s attach:c];
  r = [dev openL2CAPChannelSync:&i withPSM:PSM_INTR delegate:s];
  logf_("abrir PSM 0x13: 0x%08X", r);
  if (r == kIOReturnSuccess) [s attach:i];
}

@end

// ---------------------------------------------------------------------------
// Emparejado por USB (feature report 0xF5), igual que ds3tool
// ---------------------------------------------------------------------------

static CFIndex hid_get_feature(IOHIDDeviceRef dev, uint8_t id, uint8_t *buf, size_t cap) {
  CFIndex len = (CFIndex)cap; memset(buf, 0, cap);
  return IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, id, buf, &len) == kIOReturnSuccess ? len : -1;
}

static bool mac_in(const uint8_t *buf, CFIndex n, const uint8_t mac[6]) {
  for (CFIndex off = 0; off + 6 <= n; off++) if (memcmp(buf + off, mac, 6) == 0) return true;
  return false;
}

static int cmd_pair(const uint8_t mac[6]) {
  CFNumberRef vid = CFNumberCreate(NULL, kCFNumberSInt32Type, &kSonyVendorId);
  CFNumberRef pid = CFNumberCreate(NULL, kCFNumberSInt32Type, &kDS3ProductId);
  const void *k[2] = { CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey) };
  const void *v[2] = { vid, pid };
  CFDictionaryRef m = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  IOHIDManagerRef mgr = IOHIDManagerCreate(NULL, 0);
  IOHIDManagerSetDeviceMatching(mgr, m);
  CFSetRef set = IOHIDManagerCopyDevices(mgr);
  int ok = 0;
  if (set && CFSetGetCount(set) > 0) {
    CFIndex n = CFSetGetCount(set);
    const void **devs = calloc((size_t)n, sizeof(void *));
    CFSetGetValues(set, devs);
    for (CFIndex i = 0; i < n; i++) {
      IOHIDDeviceRef d = (IOHIDDeviceRef)devs[i];
      if (IOHIDDeviceOpen(d, 0) != kIOReturnSuccess) { printf("No se pudo abrir el mando %ld\n", (long)i); continue; }
      uint8_t buf[64];
      CFIndex len = hid_get_feature(d, 0xF2, buf, 18);
      if (len > 0) { hexline("0xF2 (MAC del mando)", buf, (size_t)len);
        printf("    -> MAC del mando (offset 4): %02X:%02X:%02X:%02X:%02X:%02X  <- apúntala para 'connect'\n",
               buf[4], buf[5], buf[6], buf[7], buf[8], buf[9]); }
      uint8_t p1[8] = { 0x01, 0x00 }; memcpy(p1 + 2, mac, 6);
      uint8_t p2[9] = { 0xF5, 0x01, 0x00 }; memcpy(p2 + 3, mac, 6);
      for (int t = 0; t < 2 && !ok; t++) {
        IOReturn r = t == 0 ? IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 0xF5, p1, sizeof p1)
                            : IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 0xF5, p2, sizeof p2);
        usleep(300000);
        len = hid_get_feature(d, 0xF5, buf, 9);
        printf("  intento %d: IOReturn 0x%08X\n", t + 1, r);
        if (len > 0) hexline("0xF5 releído", buf, (size_t)len);
        if (len > 0 && mac_in(buf, len, mac)) { printf("  OK: el mando apunta ya a este Mac.\n"); ok = 1; }
      }
      IOHIDDeviceClose(d, 0);
    }
    free(devs);
  } else {
    printf("No hay ningún DualShock 3 conectado por USB.\n");
  }
  if (set) CFRelease(set);
  CFRelease(mgr); CFRelease(m); CFRelease(pid); CFRelease(vid);
  return ok ? 0 : 1;
}

// ---------------------------------------------------------------------------

int main(int argc, char **argv) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    const char *cmd = argc > 1 ? argv[1] : "listen";

    if (strcmp(cmd, "pair") == 0) {
      uint8_t mac[6];
      if (argc > 2) {
        if (!parse_mac(argv[2], mac)) { printf("MAC no válida\n"); return 1; }
      } else {
        IOBluetoothHostController *hc = [IOBluetoothHostController defaultController];
        NSString *a = hc.addressAsString;
        if (hc.powerState != kBluetoothHCIPowerStateON || !a || !parse_mac(a.UTF8String, mac)) {
          printf("No se pudo leer la MAC Bluetooth del Mac (¿Bluetooth encendido?)\n");
          return 1;
        }
      }
      printf("MAC Bluetooth de este Mac: %02X:%02X:%02X:%02X:%02X:%02X\n", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
      return cmd_pair(mac);
    }

    IOBluetoothHostController *hc = [IOBluetoothHostController defaultController];
    if (hc.powerState != kBluetoothHCIPowerStateON) {
      printf("El Bluetooth del Mac está apagado. Enciéndelo y vuelve a probar.\n");
      return 1;
    }
    logf_("Mac %s, Bluetooth encendido", [hc.addressAsString UTF8String]);

    Listener *l = [Listener new];
    [l start];

    if (strcmp(cmd, "connect") == 0 && argc > 2) {
      NSString *addr = [NSString stringWithUTF8String:argv[2]];
      dispatch_async(dispatch_get_main_queue(), ^{ [l connectTo:addr]; });
    } else if (strcmp(cmd, "listen") == 0) {
      if (argc > 2) {
        NSString *addr = [NSString stringWithUTF8String:argv[2]];
        [l watch:addr];
      }
      logf_("Esperando... desconecta el cable y pulsa PS en el mando.");
    } else {
      printf("Uso: %s <pair [MAC] | listen | connect MAC>\n", argv[0]);
      return 1;
    }
    [[NSRunLoop currentRunLoop] run];
  }
  return 0;
}
