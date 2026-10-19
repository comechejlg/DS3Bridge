#ifndef DS3_KBD_H
#define DS3_KBD_H
#include <stdbool.h>
bool kbd_init(bool prompt);
bool kbd_trusted(void);
bool kbd_is_vhid(void);
void kbd_key(unsigned short code, bool down);
#endif
