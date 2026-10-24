// Stubs to build BTstack without BLE: the adapter may be classic-only Bluetooth
// (e.g. Bluetooth 2.1), and if BTstack sends it LE commands the stack stalls.
#include "btstack.h"
const hci_cmd_t hci_le_rand = { 0x2018, "" };
void gap_random_address_set(const bd_addr_t addr);
void gap_random_address_set(const bd_addr_t addr) { (void)addr; }
