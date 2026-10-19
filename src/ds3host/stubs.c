// Stubs para compilar BTstack sin BLE: el adaptador puede ser solo Bluetooth clásico
// (p. ej. Bluetooth 2.1), y si BTstack le manda comandos LE la pila se queda bloqueada.
#include "btstack.h"
const hci_cmd_t hci_le_rand = { 0x2018, "" };
void gap_random_address_set(const bd_addr_t addr);
void gap_random_address_set(const bd_addr_t addr) { (void)addr; }
