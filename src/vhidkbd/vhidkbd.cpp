// vhidkbd.cpp — puente entre ds3host y el teclado virtual HID de Karabiner.
//
// ds3host (usuario normal) manda por un socket Unix (datagramas) de 3 bytes:
//   [uso HID (lo), uso HID (hi), 1=pulsada / 0=soltada]
// y aquí los convertimos en reports de un teclado HID "real" (Karabiner
// DriverKit VirtualHIDDevice), que las apps leen como un teclado físico.
// Debe ejecutarse como root (lo exige el daemon de Karabiner).
// Uso: vhidkbd <ruta_socket> <uid_del_usuario>
// El socket queda con permisos 0600 y dueño = ese usuario: solo él puede mandar teclas.

#include <arpa/inet.h>
#include <atomic>
#include <csignal>
#include <iostream>
#include <mutex>
#include <netinet/in.h>
#include <pqrs/karabiner/driverkit/virtual_hid_device_driver.hpp>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>
#include <set>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace dk = pqrs::karabiner::driverkit;

static std::atomic<bool> exit_flag(false);

int main(int argc, char** argv) {
  if (argc < 3) {
    std::cout << "Uso: vhidkbd <ruta_socket> <uid_del_usuario>" << std::endl;
    return 2;
  }
  const char* sock_path = argv[1];
  uid_t owner = (uid_t)atoi(argv[2]);
  std::signal(SIGINT, [](int) { exit_flag = true; });
  std::signal(SIGTERM, [](int) { exit_flag = true; });
  std::signal(SIGHUP, [](int) { exit_flag = true; });

  pqrs::dispatcher::extra::initialize_shared_dispatcher();

  std::mutex mtx;
  std::atomic<bool> ready(false);
  auto client = std::make_unique<dk::virtual_hid_device_service::client>();

  client->connected.connect([&] {
    std::cout << "[vhidkbd] conectado al daemon de Karabiner" << std::endl;
    dk::virtual_hid_device_service::virtual_hid_keyboard_parameters p;
    p.set_country_code(pqrs::hid::country_code::us);
    client->async_virtual_hid_keyboard_initialize(p);
  });
  client->connect_failed.connect([](auto&& ec) {
    static int n = 0;
    if (n++ % 10 == 0) std::cout << "[vhidkbd] no conecta con el daemon (" << ec.message() << "), reintentando..." << std::endl;
  });
  client->driver_activated.connect([](auto&& v) {
    static std::optional<bool> prev;
    if (prev != v) { std::cout << "[vhidkbd] driver activado: " << (v ? "sí" : "NO") << std::endl; prev = v; }
  });
  client->driver_version_mismatched.connect([](auto&& v) {
    static std::optional<bool> prev;
    if (prev != v) { if (v) std::cout << "[vhidkbd] AVISO: versión del driver distinta" << std::endl; prev = v; }
  });
  client->virtual_hid_keyboard_ready.connect([&](auto&& r) {
    if (ready != r) { ready = r; std::cout << "[vhidkbd] teclado virtual " << (r ? "LISTO" : "no listo") << std::endl; }
  });
  client->async_start();

  int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
  sockaddr_un a{};
  a.sun_family = AF_UNIX;
  strlcpy(a.sun_path, sock_path, sizeof a.sun_path);
  unlink(sock_path);
  if (bind(fd, (sockaddr*)&a, sizeof a) != 0) {
    std::cout << "[vhidkbd] no se pudo crear " << sock_path << std::endl;
    return 1;
  }
  chown(sock_path, owner, 0);
  chmod(sock_path, 0600);
  timeval tv{0, 200000};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  std::cout << "[vhidkbd] esperando teclas de ds3host en " << sock_path << " (uid " << owner << ")" << std::endl;

  std::set<uint16_t> keys;
  uint8_t buf[16];
  while (!exit_flag) {
    ssize_t n = recv(fd, buf, sizeof buf, 0);
    if (n < 3) continue;
    uint16_t usage = (uint16_t)(buf[0] | (buf[1] << 8));
    if (buf[2]) keys.insert(usage); else keys.erase(usage);
    if (usage == 0xFFFF) keys.clear();          // "suelta todo"
    dk::virtual_hid_device_driver::hid_report::keyboard_input report;
    for (auto k : keys) if (k != 0xFFFF) report.keys.insert(k);
    std::lock_guard<std::mutex> lock(mtx);
    if (ready) client->async_post_report(report);
  }

  // Al salir: soltar todas las teclas.
  {
    dk::virtual_hid_device_driver::hid_report::keyboard_input empty;
    if (ready) client->async_post_report(empty);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  close(fd);
  unlink(sock_path);
  client = nullptr;
  pqrs::dispatcher::extra::terminate_shared_dispatcher();
  std::cout << "[vhidkbd] cerrado" << std::endl;
  return 0;
}
