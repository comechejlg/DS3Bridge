// vhidkbd.cpp — bridge between ds3host and the Karabiner virtual HID keyboard.
//
// ds3host (normal user) sends 3-byte datagrams over a Unix socket:
//   [HID usage (lo), HID usage (hi), 1 = pressed / 0 = released]
// and here they become reports of a "real" HID keyboard (Karabiner
// DriverKit VirtualHIDDevice), which apps read as a physical keyboard.
// Must run as root (required by the Karabiner daemon).
// Usage: vhidkbd <socket_path> <user_uid>
// The socket gets mode 0600 and owner = that user: only they can send keys.

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
    std::cout << "Usage: vhidkbd <socket_path> <user_uid>" << std::endl;
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
    std::cout << "[vhidkbd] connected to the Karabiner daemon" << std::endl;
    dk::virtual_hid_device_service::virtual_hid_keyboard_parameters p;
    p.set_country_code(pqrs::hid::country_code::us);
    client->async_virtual_hid_keyboard_initialize(p);
  });
  client->connect_failed.connect([](auto&& ec) {
    static int n = 0;
    if (n++ % 10 == 0) std::cout << "[vhidkbd] cannot reach the daemon (" << ec.message() << "), retrying..." << std::endl;
  });
  client->driver_activated.connect([](auto&& v) {
    static std::optional<bool> prev;
    if (prev != v) { std::cout << "[vhidkbd] driver activated: " << (v ? "yes" : "NO") << std::endl; prev = v; }
  });
  client->driver_version_mismatched.connect([](auto&& v) {
    static std::optional<bool> prev;
    if (prev != v) { if (v) std::cout << "[vhidkbd] WARNING: driver version mismatch" << std::endl; prev = v; }
  });
  client->virtual_hid_keyboard_ready.connect([&](auto&& r) {
    if (ready != r) { ready = r; std::cout << "[vhidkbd] virtual keyboard " << (r ? "READY" : "not ready") << std::endl; }
  });
  client->async_start();

  int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
  sockaddr_un a{};
  a.sun_family = AF_UNIX;
  strlcpy(a.sun_path, sock_path, sizeof a.sun_path);
  unlink(sock_path);
  if (bind(fd, (sockaddr*)&a, sizeof a) != 0) {
    std::cout << "[vhidkbd] could not create " << sock_path << std::endl;
    return 1;
  }
  chown(sock_path, owner, 0);
  chmod(sock_path, 0600);
  timeval tv{0, 200000};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  std::cout << "[vhidkbd] waiting for keys from ds3host on " << sock_path << " (uid " << owner << ")" << std::endl;

  std::set<uint16_t> keys;
  uint8_t buf[16];
  while (!exit_flag) {
    ssize_t n = recv(fd, buf, sizeof buf, 0);
    if (n < 3) continue;
    uint16_t usage = (uint16_t)(buf[0] | (buf[1] << 8));
    if (buf[2]) keys.insert(usage); else keys.erase(usage);
    if (usage == 0xFFFF) keys.clear();          // "release all"
    dk::virtual_hid_device_driver::hid_report::keyboard_input report;
    for (auto k : keys) if (k != 0xFFFF) report.keys.insert(k);
    std::lock_guard<std::mutex> lock(mtx);
    if (ready) client->async_post_report(report);
  }

  // On exit: release every key.
  {
    dk::virtual_hid_device_driver::hid_report::keyboard_input empty;
    if (ready) client->async_post_report(empty);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  close(fd);
  unlink(sock_path);
  client = nullptr;
  pqrs::dispatcher::extra::terminate_shared_dispatcher();
  std::cout << "[vhidkbd] closed" << std::endl;
  return 0;
}
