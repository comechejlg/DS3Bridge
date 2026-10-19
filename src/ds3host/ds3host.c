//
// ds3host.c — Host Bluetooth propio para el DualShock 3 sobre un adaptador USB.
//
// Usa BTstack (libusb) para controlar un adaptador Bluetooth USB que macOS no
// usa. Al ser nuestra propia pila, aceptamos los canales HID del DS3 sin exigir
// emparejamiento (el DS3 no sabe hacerlo), igual que hacía la PS3.
//
// BTstack: (c) BlueKitchen GmbH — gratuito para uso personal/no comercial.
//

#define BTSTACK_FILE__ "ds3host.c"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "btstack.h"

#define PSM_HID_CONTROL   0x11
#define PSM_HID_INTERRUPT 0x13
#define MAX_PADS          4

typedef struct {
  bool             used;
  hci_con_handle_t handle;
  bd_addr_t        addr;
  uint16_t         ctrl_cid, intr_cid;
  bool             ctrl_open, intr_open;
  bool             need_enable, need_output;
  bool             rumble_on;
  uint8_t          stage;         // 1 = falta el saludo con vibración, 2 = falta apagarla
  uint32_t         reports;
  uint8_t          slot;          // 0..3 -> LED 1..4
} ds3_t;

static ds3_t pads[MAX_PADS];
static btstack_packet_callback_registration_t hci_cb;
static btstack_timer_source_t rumble_timer;
static bool kbd_enabled;

static const char *kButtons[17] = {
  "SELECT", "L3", "R3", "START", "UP", "RIGHT", "DOWN", "LEFT",
  "L2", "R2", "L1", "R1", "TRI", "CIRC", "CROSS", "SQUARE", "PS"
};

static void stamp(void) {
  struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
  struct tm tm; localtime_r(&ts.tv_sec, &tm);
  printf("[%02d:%02d:%02d.%03ld] ", tm.tm_hour, tm.tm_min, tm.tm_sec, ts.tv_nsec / 1000000);
}
#define LOG(...) do { stamp(); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static ds3_t *pad_by_handle(hci_con_handle_t h) {
  for (int i = 0; i < MAX_PADS; i++) if (pads[i].used && pads[i].handle == h) return &pads[i];
  return NULL;
}
static ds3_t *pad_by_cid(uint16_t cid) {
  for (int i = 0; i < MAX_PADS; i++)
    if (pads[i].used && (pads[i].ctrl_cid == cid || pads[i].intr_cid == cid)) return &pads[i];
  return NULL;
}
static ds3_t *pad_new(hci_con_handle_t h, bd_addr_t a) {
  ds3_t *p = pad_by_handle(h);
  if (p) return p;
  for (int i = 0; i < MAX_PADS; i++) if (!pads[i].used) {
    memset(&pads[i], 0, sizeof pads[i]);
    pads[i].used = true; pads[i].handle = h; pads[i].slot = (uint8_t)i;
    bd_addr_copy(pads[i].addr, a);
    return &pads[i];
  }
  return NULL;
}

// Report de salida 0x01 (36 bytes, igual que hid-sony en Linux).
static void build_output(ds3_t *p, uint8_t out[36], bool rumble) {
  static const uint8_t base[36] = {
    0x01,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00,
    0xFF, 0x27, 0x10, 0x00, 0x32,
    0xFF, 0x27, 0x10, 0x00, 0x32,
    0xFF, 0x27, 0x10, 0x00, 0x32,
    0xFF, 0x27, 0x10, 0x00, 0x32,
    0x00, 0x00, 0x00, 0x00, 0x00,
  };
  memcpy(out, base, 36);
  if (rumble) { out[2] = 0xFE; out[3] = 0xFF; out[4] = 0xFE; out[5] = 0xFF; }
  // LED: el del número de mando; si el modo teclado está en pausa, LED 4.
  out[10] = kbd_enabled ? (uint8_t)(0x02 << p->slot) : 0x10;
}

static void request_send(ds3_t *p) {
  if (p->ctrl_open) l2cap_request_can_send_now_event(p->ctrl_cid);
}

// Secuencia de saludo: 300 ms después de activar -> LED + vibración; 600 ms más -> sin vibración.
// (Si el report de salida llega pegado a la activación, el mando contesta NOT_READY y lo ignora.)
static void startup_step(btstack_timer_source_t *ts) {
  bool again = false;
  for (int i = 0; i < MAX_PADS; i++) {
    ds3_t *p = &pads[i];
    if (!p->used || !p->ctrl_open) continue;
    if (p->stage == 1)      { p->rumble_on = true;  p->stage = 2; again = true; }
    else if (p->stage == 2) { p->rumble_on = false; p->stage = 0; }
    else continue;
    p->need_output = true; request_send(p);
  }
  if (again) { btstack_run_loop_set_timer(ts, 600); btstack_run_loop_add_timer(ts); }
}
static void start_greeting(void) {
  btstack_run_loop_remove_timer(&rumble_timer);
  btstack_run_loop_set_timer_handler(&rumble_timer, startup_step);
  btstack_run_loop_set_timer(&rumble_timer, 300);
  btstack_run_loop_add_timer(&rumble_timer);
}

static void ctrl_can_send(ds3_t *p) {
  if (p->need_enable) {
    // SET_REPORT | Feature 0xF4: modo operativo por Bluetooth.
    static const uint8_t enable[] = { 0x53, 0xF4, 0x42, 0x03, 0x00, 0x00 };
    l2cap_send(p->ctrl_cid, (uint8_t *)enable, sizeof enable);
    p->need_enable = false;
    LOG("-> activación (F4 42 03) enviada");
    p->stage = 1; start_greeting();
    if (p->need_output) request_send(p);
    return;
  }
  if (p->need_output) {
    uint8_t pkt[37]; pkt[0] = 0x52;   // SET_REPORT | Output
    bool rumble = p->rumble_on;
    build_output(p, pkt + 1, rumble);
    l2cap_send(p->ctrl_cid, pkt, sizeof pkt);
    p->need_output = false;
    LOG("-> LED %u%s", p->slot + 1, rumble ? " + vibración" : "");
  }
}

// ---------------------------------------------------------------------------
// Estado normalizado del mando
// ---------------------------------------------------------------------------
// Los botones sensibles a la presión (cruceta, L1/L2/R1/R2 y los 4 de la derecha)
// se deciden por su valor analógico con un umbral: el bit digital de algunos
// mandos se queda "pulsado" en reposo (sensores con 15-30 de presión residual).

#define PRESS_ON  70
#define PRESS_OFF 50

enum { B_SELECT, B_L3, B_R3, B_START, B_UP, B_RIGHT, B_DOWN, B_LEFT,
       B_L2, B_R2, B_L1, B_R1, B_TRI, B_CIRC, B_CROSS, B_SQUARE, B_PS };

typedef struct {
  uint32_t buttons;              // bit = 1 << B_*
  uint8_t  lx, ly, rx, ry;
  uint8_t  pr[12];               // presiones: up right down left L2 R2 L1 R1 tri circ cross square
  int16_t  acc[3], gyro;
  uint8_t  battery;
} pad_state_t;

static pad_state_t states[MAX_PADS];

static void decode(int slot, const uint8_t *r) {
  pad_state_t *s = &states[slot];
  uint32_t b = 0;
  if (r[2] & 0x01) b |= 1u << B_SELECT;
  if (r[2] & 0x02) b |= 1u << B_L3;
  if (r[2] & 0x04) b |= 1u << B_R3;
  if (r[2] & 0x08) b |= 1u << B_START;
  if (r[4] & 0x01) b |= 1u << B_PS;
  // Presiones (offset 14..25) en el mismo orden que los bits B_UP..B_SQUARE.
  for (int k = 0; k < 12; k++) {
    uint8_t v = r[14 + k];
    bool was = (s->buttons >> (B_UP + k)) & 1u;
    if (v >= PRESS_ON || (was && v >= PRESS_OFF)) b |= 1u << (B_UP + k);
    // Presión "limpia": por debajo del umbral de reposo cuenta como 0.
    s->pr[k] = v < PRESS_OFF ? 0 : v;
  }
  s->buttons = b;
  s->lx = r[6]; s->ly = r[7]; s->rx = r[8]; s->ry = r[9];
  s->acc[0] = (int16_t)((r[41] << 8) | r[42]);
  s->acc[1] = (int16_t)((r[43] << 8) | r[44]);
  s->acc[2] = (int16_t)((r[45] << 8) | r[46]);
  s->gyro   = (int16_t)((r[47] << 8) | r[48]);
  s->battery = r[30];
}

// ---------------------------------------------------------------------------
// Modo teclado (OpenEmu y cualquier app que lea el teclado). PS lo activa/desactiva.
// ---------------------------------------------------------------------------

#include "kbd.h"

// Teclas virtuales de macOS (kVK_*).
enum { K_A = 0x00, K_S = 0x01, K_D = 0x02, K_F = 0x03, K_H = 0x04, K_Z = 0x06, K_X = 0x07,
       K_C = 0x08, K_V = 0x09, K_Q = 0x0C, K_W = 0x0D, K_E = 0x0E, K_1 = 0x12, K_3 = 0x14,
       K_I = 0x22, K_L = 0x25, K_J = 0x26, K_K = 0x28, K_N = 0x2D, K_M = 0x2E,
       K_RETURN = 0x24, K_LEFT = 0x7B, K_RIGHT = 0x7C, K_DOWN = 0x7D, K_UP = 0x7E };

// Botón -> tecla (orden de B_*; 0xFFFF = sin tecla).
static const unsigned short kKeyFor[17] = {
  /* SELECT */ K_N, /* L3 */ K_F, /* R3 */ K_H, /* START */ K_RETURN,
  /* UP */ K_UP, /* RIGHT */ K_RIGHT, /* DOWN */ K_DOWN, /* LEFT */ K_LEFT,
  /* L2 */ K_1, /* R2 */ K_3, /* L1 */ K_Q, /* R1 */ K_E,
  /* TRI */ K_V, /* CIRC */ K_C, /* CROSS */ K_X, /* SQUARE */ K_Z, /* PS */ 0xFFFF
};
// Sticks como 4 direcciones digitales: izquierdo = WASD, derecho = IJKL.
enum { S_LU, S_LD, S_LL, S_LR, S_RU, S_RD, S_RL, S_RR, S_COUNT };
static const unsigned short kStickKey[S_COUNT] = { K_W, K_S, K_A, K_D, K_I, K_K, K_J, K_L };

static bool kbd_enabled = true;
static bool kbd_ok = false;
static uint32_t kbd_buttons[MAX_PADS];
static uint8_t  kbd_sticks[MAX_PADS];

static void stick_bits(uint8_t v, int lo, int hi, uint8_t *bits, uint8_t prev) {
  // Umbral con histéresis: entra a 60 del centro, sale a 40.
  int d = (int)v - 128;
  bool was_lo = (prev >> lo) & 1, was_hi = (prev >> hi) & 1;
  if (d <= -60 || (was_lo && d <= -40)) *bits |= (uint8_t)(1u << lo);
  if (d >=  60 || (was_hi && d >=  40)) *bits |= (uint8_t)(1u << hi);
}

static void kbd_release_all(int slot) {
  for (int i = 0; i < 17; i++)
    if ((kbd_buttons[slot] >> i) & 1u && kKeyFor[i] != 0xFFFF) kbd_key(kKeyFor[i], false);
  for (int i = 0; i < S_COUNT; i++) if ((kbd_sticks[slot] >> i) & 1u) kbd_key(kStickKey[i], false);
  kbd_buttons[slot] = 0; kbd_sticks[slot] = 0;
}

static void request_send(ds3_t *p);
static void kbd_update(ds3_t *p) {
  int slot = p->slot;
  pad_state_t *s = &states[slot];
  uint32_t now = s->buttons;

  // PS (flanco de subida) activa/desactiva el modo teclado. LED1 = activo, LED4 = pausado.
  static uint32_t ps_prev[MAX_PADS];
  bool ps = (now >> B_PS) & 1u;
  if (ps && !((ps_prev[slot] >> B_PS) & 1u)) {
    kbd_enabled = !kbd_enabled;
    if (!kbd_enabled) kbd_release_all(slot);
    printf("\n"); LOG("Modo teclado %s", kbd_enabled ? "ACTIVADO" : "PAUSADO");
    p->need_output = true; request_send(p);
  }
  ps_prev[slot] = now;
  if (!kbd_enabled || !kbd_ok) return;

  uint32_t diff = now ^ kbd_buttons[slot];
  for (int i = 0; i < 17; i++)
    if ((diff >> i) & 1u && kKeyFor[i] != 0xFFFF) kbd_key(kKeyFor[i], (now >> i) & 1u);
  kbd_buttons[slot] = now;

  uint8_t st = 0, prev = kbd_sticks[slot];
  stick_bits(s->ly, S_LU, S_LD, &st, prev);
  stick_bits(s->lx, S_LL, S_LR, &st, prev);
  stick_bits(s->ry, S_RU, S_RD, &st, prev);
  stick_bits(s->rx, S_RL, S_RR, &st, prev);
  uint8_t sd = st ^ prev;
  for (int i = 0; i < S_COUNT; i++) if ((sd >> i) & 1u) kbd_key(kStickKey[i], (st >> i) & 1u);
  kbd_sticks[slot] = st;
}

static void print_state(ds3_t *p) {
  pad_state_t *s = &states[p->slot];
  char btn[128] = "";
  for (int i = 0; i < 17; i++) if (s->buttons & (1u << i)) { strcat(btn, kButtons[i]); strcat(btn, " "); }
  printf("\r  [%u] L(%3u,%3u) R(%3u,%3u) L2=%3u R2=%3u  %-46s",
         p->slot + 1, s->lx, s->ly, s->rx, s->ry, s->pr[4], s->pr[5], btn);
  fflush(stdout);
}

// ---------------------------------------------------------------------------
// Servidor DSU ("cemuhook"), UDP 127.0.0.1:26760 — lo leen Dolphin, Cemu, etc.
// ---------------------------------------------------------------------------

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#define DSU_PORT 26760
#define DSU_PROTO 1001
#define DSU_MAX_CLIENTS 8

typedef struct { struct sockaddr_in addr; uint32_t last_ms; bool used; } dsu_client_t;

static int dsu_fd = -1;
static uint32_t dsu_server_id;
static dsu_client_t dsu_clients[DSU_MAX_CLIENTS];
static uint32_t dsu_packet_no[MAX_PADS];
static btstack_data_source_t dsu_ds;

static uint32_t crc32_table[256];
static void crc32_init(void) {
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
    crc32_table[i] = c;
  }
}
static uint32_t crc32_calc(const uint8_t *d, size_t n) {
  uint32_t c = 0xFFFFFFFFu;
  for (size_t i = 0; i < n; i++) c = crc32_table[(c ^ d[i]) & 0xFF] ^ (c >> 8);
  return c ^ 0xFFFFFFFFu;
}

static void put16(uint8_t *p, uint16_t v) { p[0] = v & 0xFF; p[1] = v >> 8; }
static void put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (v >> (8 * i)) & 0xFF; }
static void putf(uint8_t *p, float f) { uint32_t v; memcpy(&v, &f, 4); put32(p, v); }

// Cabecera (16) + tipo de mensaje (4). Devuelve el puntero al cuerpo.
static uint8_t *dsu_begin(uint8_t *pkt, uint32_t type) {
  memcpy(pkt, "DSUS", 4);
  put16(pkt + 4, DSU_PROTO);
  put32(pkt + 12, dsu_server_id);
  put32(pkt + 16, type);
  return pkt + 20;
}
static void dsu_finish_send(uint8_t *pkt, size_t len, const struct sockaddr_in *to) {
  put16(pkt + 6, (uint16_t)(len - 16));
  put32(pkt + 8, 0);
  put32(pkt + 8, crc32_calc(pkt, len));
  sendto(dsu_fd, pkt, len, 0, (const struct sockaddr *)to, sizeof *to);
}

static uint8_t dsu_battery(uint8_t b) {
  switch (b) { case 0xEE: return 0xEE; case 0xEF: return 0xEF; case 0x05: return 0x05;
               case 0x04: return 0x04; case 0x03: return 0x03; case 0x02: return 0x02;
               case 0x01: return 0x01; default: return 0x00; }
}

// Los 11 bytes comunes: slot, estado, modelo, conexión, MAC, batería.
static uint8_t *dsu_shared(uint8_t *p, int slot) {
  bool on = slot < MAX_PADS && pads[slot].used && pads[slot].intr_open;
  p[0] = (uint8_t)slot;
  p[1] = on ? 2 : 0;          // 2 = conectado
  p[2] = on ? 2 : 0;          // 2 = giroscopio completo (aprox. en el DS3)
  p[3] = on ? 2 : 0;          // 2 = Bluetooth
  if (on) for (int i = 0; i < 6; i++) p[4 + i] = pads[slot].addr[i]; else memset(p + 4, 0, 6);
  p[10] = on ? dsu_battery(states[slot].battery) : 0;
  return p + 11;
}

static void dsu_send_data(int slot, const struct sockaddr_in *to) {
  pad_state_t *s = &states[slot];
  uint8_t pkt[100]; memset(pkt, 0, sizeof pkt);
  uint8_t *p = dsu_shared(dsu_begin(pkt, 0x100002), slot);
  uint32_t b = s->buttons;
  *p++ = 1;                                         // conectado
  put32(p, dsu_packet_no[slot]); p += 4;
  uint8_t b1 = 0, b2 = 0;
  if (b & (1u << B_LEFT))   b1 |= 0x80;
  if (b & (1u << B_DOWN))   b1 |= 0x40;
  if (b & (1u << B_RIGHT))  b1 |= 0x20;
  if (b & (1u << B_UP))     b1 |= 0x10;
  if (b & (1u << B_START))  b1 |= 0x08;
  if (b & (1u << B_R3))     b1 |= 0x04;
  if (b & (1u << B_L3))     b1 |= 0x02;
  if (b & (1u << B_SELECT)) b1 |= 0x01;
  if (b & (1u << B_TRI))    b2 |= 0x80;
  if (b & (1u << B_CIRC))   b2 |= 0x40;
  if (b & (1u << B_CROSS))  b2 |= 0x20;
  if (b & (1u << B_SQUARE)) b2 |= 0x10;
  if (b & (1u << B_R1))     b2 |= 0x08;
  if (b & (1u << B_L1))     b2 |= 0x04;
  if (b & (1u << B_R2))     b2 |= 0x02;
  if (b & (1u << B_L2))     b2 |= 0x01;
  *p++ = b1; *p++ = b2;
  *p++ = (b & (1u << B_PS)) ? 1 : 0;               // botón PS / Home
  *p++ = 0;                                         // botón táctil
  *p++ = s->lx; *p++ = (uint8_t)(255 - s->ly);      // DSU: Y positivo hacia arriba
  *p++ = s->rx; *p++ = (uint8_t)(255 - s->ry);
  // Analógicos: cruceta L, D, R, U; luego Y(tri) B(circ) A(cross) X(square); R1 L1 R2 L2
  *p++ = s->pr[3]; *p++ = s->pr[2]; *p++ = s->pr[1]; *p++ = s->pr[0];
  *p++ = s->pr[8]; *p++ = s->pr[9]; *p++ = s->pr[10]; *p++ = s->pr[11];
  *p++ = s->pr[7]; *p++ = s->pr[6]; *p++ = s->pr[5]; *p++ = s->pr[4];
  p += 12;                                          // 2 toques táctiles (vacíos)
  uint64_t us = (uint64_t)btstack_run_loop_get_time_ms() * 1000u;
  for (int i = 0; i < 8; i++) *p++ = (uint8_t)(us >> (8 * i));
  // Acelerómetro: ~512 = 0 g, ~113 unidades por g (aprox.). Giro: solo eje Z.
  putf(p, -(s->acc[0] - 512) / 113.0f); p += 4;
  putf(p,  (s->acc[2] - 512) / 113.0f); p += 4;
  putf(p, -(s->acc[1] - 512) / 113.0f); p += 4;
  putf(p, 0.0f); p += 4;                                     // pitch
  putf(p, -(s->gyro - 498) * 1.0f); p += 4;                  // yaw (aprox.)
  putf(p, 0.0f); p += 4;                                     // roll
  dsu_finish_send(pkt, (size_t)(p - pkt), to);
}

static void dsu_broadcast(int slot) {
  uint32_t now = btstack_run_loop_get_time_ms();
  dsu_packet_no[slot]++;
  for (int i = 0; i < DSU_MAX_CLIENTS; i++) {
    if (!dsu_clients[i].used) continue;
    if (now - dsu_clients[i].last_ms > 5000) { dsu_clients[i].used = false; continue; }
    dsu_send_data(slot, &dsu_clients[i].addr);
  }
}

static void dsu_register(const struct sockaddr_in *from) {
  uint32_t now = btstack_run_loop_get_time_ms();
  int free_i = -1;
  for (int i = 0; i < DSU_MAX_CLIENTS; i++) {
    if (dsu_clients[i].used && dsu_clients[i].addr.sin_addr.s_addr == from->sin_addr.s_addr &&
        dsu_clients[i].addr.sin_port == from->sin_port) { dsu_clients[i].last_ms = now; return; }
    if (!dsu_clients[i].used && free_i < 0) free_i = i;
  }
  if (free_i < 0) return;
  dsu_clients[free_i].used = true; dsu_clients[free_i].addr = *from; dsu_clients[free_i].last_ms = now;
  printf("\n"); LOG("DSU: cliente conectado (%s:%u)", inet_ntoa(from->sin_addr), ntohs(from->sin_port));
}

static void dsu_on_readable(btstack_data_source_t *ds, btstack_data_source_callback_type_t type) {
  (void)ds; (void)type;
  uint8_t buf[256]; struct sockaddr_in from; socklen_t fl = sizeof from;
  ssize_t n;
  while ((n = recvfrom(dsu_fd, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl)) > 0) {
    if (n < 20 || memcmp(buf, "DSUC", 4) != 0) continue;
    uint32_t msg = (uint32_t)buf[16] | ((uint32_t)buf[17] << 8) | ((uint32_t)buf[18] << 16) | ((uint32_t)buf[19] << 24);
    uint8_t pkt[64];
    if (msg == 0x100000) {                         // versión
      uint8_t *p = dsu_begin(memset(pkt, 0, sizeof pkt), 0x100000);
      put16(p, DSU_PROTO); p += 2;
      dsu_finish_send(pkt, (size_t)(p - pkt), &from);
    } else if (msg == 0x100001 && n >= 24) {       // info de puertos
      int32_t cnt = (int32_t)(buf[20] | (buf[21] << 8) | (buf[22] << 16) | (buf[23] << 24));
      for (int i = 0; i < cnt && i < 4 && 24 + i < n; i++) {
        uint8_t slot = buf[24 + i]; if (slot >= 4) continue;
        uint8_t *p = dsu_shared(dsu_begin(memset(pkt, 0, sizeof pkt), 0x100001), slot);
        *p++ = 0;
        dsu_finish_send(pkt, (size_t)(p - pkt), &from);
      }
    } else if (msg == 0x100002) {                  // suscripción a datos
      dsu_register(&from);
    }
    fl = sizeof from;
  }
}

static void dsu_start(void) {
  crc32_init();
  dsu_server_id = (uint32_t)time(NULL) ^ 0xD53B0000u;
  dsu_fd = socket(AF_INET, SOCK_DGRAM, 0);
  struct sockaddr_in a; memset(&a, 0, sizeof a);
  a.sin_family = AF_INET; a.sin_port = htons(DSU_PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int one = 1; setsockopt(dsu_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  if (bind(dsu_fd, (struct sockaddr *)&a, sizeof a) != 0) { LOG("DSU: no se pudo abrir el puerto %d", DSU_PORT); close(dsu_fd); dsu_fd = -1; return; }
  fcntl(dsu_fd, F_SETFL, fcntl(dsu_fd, F_GETFL) | O_NONBLOCK);
  btstack_run_loop_set_data_source_fd(&dsu_ds, dsu_fd);
  btstack_run_loop_set_data_source_handler(&dsu_ds, dsu_on_readable);
  btstack_run_loop_enable_data_source_callbacks(&dsu_ds, DATA_SOURCE_CALLBACK_READ);
  btstack_run_loop_add_data_source(&dsu_ds);
  LOG("Servidor DSU escuchando en 127.0.0.1:%d", DSU_PORT);
}

static void l2cap_handler(uint8_t type, uint16_t channel, uint8_t *packet, uint16_t size) {
  if (type == L2CAP_DATA_PACKET) {
    ds3_t *p = pad_by_cid(channel);
    if (!p) return;
    if (channel == p->intr_cid && size >= 50 && packet[0] == 0xA1 && packet[1] == 0x01) {
      if (p->reports++ == 0) { LOG("¡Llegan datos del mando %u! (Ctrl-C para salir)", p->slot + 1); }
      decode(p->slot, packet + 1);
      dsu_broadcast(p->slot);
      kbd_update(p);
      if ((p->reports % 5) == 0) print_state(p);
    } else if (channel == p->ctrl_cid) {
      if (!(size == 1 && packet[0] == 0x00)) { stamp(); printf("<- control (%u):", size);
        for (int i = 0; i < size && i < 16; i++) printf(" %02X", packet[i]); printf("\n"); }
    }
    return;
  }
  if (type != HCI_EVENT_PACKET) return;

  switch (hci_event_packet_get_type(packet)) {
    case L2CAP_EVENT_INCOMING_CONNECTION: {
      uint16_t psm = l2cap_event_incoming_connection_get_psm(packet);
      uint16_t cid = l2cap_event_incoming_connection_get_local_cid(packet);
      bd_addr_t a; l2cap_event_incoming_connection_get_address(packet, a);
      LOG("canal entrante PSM 0x%02X desde %s -> aceptado", psm, bd_addr_to_str(a));
      l2cap_accept_connection(cid);
      break;
    }
    case L2CAP_EVENT_CHANNEL_OPENED: {
      uint8_t st = l2cap_event_channel_opened_get_status(packet);
      uint16_t psm = l2cap_event_channel_opened_get_psm(packet);
      uint16_t cid = l2cap_event_channel_opened_get_local_cid(packet);
      hci_con_handle_t h = l2cap_event_channel_opened_get_handle(packet);
      bd_addr_t a; l2cap_event_channel_opened_get_address(packet, a);
      if (st) { LOG("canal PSM 0x%02X falló (0x%02X)", psm, st); break; }
      ds3_t *p = pad_new(h, a);
      if (!p) { LOG("demasiados mandos"); l2cap_disconnect(cid); break; }
      if (psm == PSM_HID_CONTROL)   { p->ctrl_cid = cid; p->ctrl_open = true; }
      if (psm == PSM_HID_INTERRUPT) { p->intr_cid = cid; p->intr_open = true; }
      LOG("canal PSM 0x%02X abierto (mando %u)", psm, p->slot + 1);
      if (p->ctrl_open && p->intr_open) {
        p->need_enable = true;
        request_send(p);
      }
      break;
    }
    case L2CAP_EVENT_CAN_SEND_NOW: {
      ds3_t *p = pad_by_cid(l2cap_event_can_send_now_get_local_cid(packet));
      if (p) ctrl_can_send(p);
      break;
    }
    case L2CAP_EVENT_CHANNEL_CLOSED: {
      uint16_t cid = l2cap_event_channel_closed_get_local_cid(packet);
      ds3_t *p = pad_by_cid(cid);
      if (!p) break;
      printf("\n");
      LOG("canal cerrado (mando %u)", p->slot + 1);
      if (cid == p->ctrl_cid) { p->ctrl_open = false; p->ctrl_cid = 0; }
      if (cid == p->intr_cid) { p->intr_open = false; p->intr_cid = 0; }
      if (!p->ctrl_open && !p->intr_open) { kbd_release_all(p->slot); p->used = false; memset(&states[p->slot], 0, sizeof states[0]); }
      break;
    }
    default: break;
  }
}

// Guarda la dirección Bluetooth del adaptador para que el script de emparejado
// sepa qué dirección grabar en el mando (no hay que escribirla a mano).
static void save_adapter_address(bd_addr_t a) {
  const char *home = getenv("HOME");
  if (!home) return;
  char dir[512], path[600];
  snprintf(dir, sizeof dir, "%s/Library/Application Support/DS3Bridge", home);
  mkdir(dir, 0755);
  snprintf(path, sizeof path, "%s/adapter-address", dir);
  FILE *f = fopen(path, "w");
  if (!f) return;
  fprintf(f, "%s\n", bd_addr_to_str(a));
  fclose(f);
}

static void hci_handler(uint8_t type, uint16_t channel, uint8_t *packet, uint16_t size) {
  (void)channel; (void)size;
  if (type != HCI_EVENT_PACKET) return;
  bd_addr_t a;
  switch (hci_event_packet_get_type(packet)) {
    case BTSTACK_EVENT_STATE:
      if (btstack_event_state_get_state(packet) == HCI_STATE_WORKING) {
        gap_local_bd_addr(a);
        printf("\n");
        LOG("Adaptador listo. Dirección Bluetooth del adaptador: %s", bd_addr_to_str(a));
        save_adapter_address(a);
        LOG("Esperando al DualShock 3... (pulsa PS)");
      }
      break;
    case HCI_EVENT_CONNECTION_REQUEST:
      hci_event_connection_request_get_bd_addr(packet, a);
      LOG("petición de conexión de %s", bd_addr_to_str(a));
      break;
    case HCI_EVENT_CONNECTION_COMPLETE:
      hci_event_connection_complete_get_bd_addr(packet, a);
      LOG("enlace con %s: status 0x%02X", bd_addr_to_str(a), hci_event_connection_complete_get_status(packet));
      break;
    case HCI_EVENT_DISCONNECTION_COMPLETE:
      printf("\n");
      LOG("enlace cerrado (motivo 0x%02X)", hci_event_disconnection_complete_get_reason(packet));
      break;
    case HCI_EVENT_PIN_CODE_REQUEST:
      // No debería pasar con el DS3; si pasa, lo rechazamos en lugar de colgar.
      hci_event_pin_code_request_get_bd_addr(packet, a);
      LOG("petición de PIN de %s -> rechazada", bd_addr_to_str(a));
      gap_pin_code_negative(a);
      break;
    default: break;
  }
}

int btstack_main(int argc, const char *argv[]);
int btstack_main(int argc, const char *argv[]) {
  (void)argc; (void)argv;
  setvbuf(stdout, NULL, _IOLBF, 0);

  hci_cb.callback = &hci_handler;
  hci_add_event_handler(&hci_cb);

  l2cap_init();
  // Nivel de seguridad 0: sin autenticación ni cifrado, como la PS3.
  gap_set_security_mode(GAP_SECURITY_MODE_2);
  gap_set_security_level(LEVEL_0);
  gap_ssp_set_enable(0);
  l2cap_register_service(l2cap_handler, PSM_HID_CONTROL,   100, LEVEL_0);
  l2cap_register_service(l2cap_handler, PSM_HID_INTERRUPT, 100, LEVEL_0);

  gap_set_local_name("DS3Bridge");
  gap_set_class_of_device(0x0C010C);   // ordenador portátil
  gap_connectable_control(1);
  gap_discoverable_control(0);

  dsu_start();
  kbd_enabled = true;
  kbd_ok = kbd_init(true);
  if (kbd_ok && kbd_is_vhid()) LOG("Modo teclado: teclado virtual HID de Karabiner (PS lo pausa/reanuda).");
  else if (kbd_ok) LOG("Modo teclado listo (PS lo pausa/reanuda).");
  else LOG("Modo teclado SIN PERMISO: activa Terminal en Ajustes > Privacidad y seguridad > Accesibilidad y reinicia el programa.");
  hci_power_control(HCI_POWER_ON);
  return 0;
}
