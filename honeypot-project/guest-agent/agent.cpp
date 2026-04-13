/*
 * Enterprise Dynamic Honeypot — Guest Agent (Firecracker microVM)
 *
 * Architecture: This minimal C++ process runs inside the guest. It presents a
 * fake bash prompt, forwards attacker keystrokes (one line per "command") to
 * the host over AF_VSOCK, and prints whatever the host returns (synthetic
 * terminal output produced by the Python interceptor + local LLM).
 *
 * Wire protocol (guest -> host): one UTF-8 line per command, terminated by '\n'.
 * Wire protocol (host -> guest): big-endian uint32 length + raw UTF-8 payload
 * (supports multi-line LLM output without ambiguous delimiters).
 */

#include <arpa/inet.h>
#include <linux/vm_sockets.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>

using namespace std;

namespace {

constexpr int kVsockPort = 1234;

// Read exactly `n` bytes into `buf` or return false on EOF/error.
bool recv_all(int fd, void *buf, size_t n) {
  auto *p = static_cast<unsigned char *>(buf);
  size_t got = 0;
  while (got < n) {
    ssize_t r = ::recv(fd, p + got, n - got, 0);
    if (r <= 0) {
      return false;
    }
    got += static_cast<size_t>(r);
  }
  return true;
}

// Send entire buffer (handles partial writes).
bool send_all(int fd, const void *buf, size_t n) {
  const auto *p = static_cast<const unsigned char *>(buf);
  size_t sent = 0;
  while (sent < n) {
    ssize_t w = ::send(fd, p + sent, n - sent, 0);
    if (w <= 0) {
      return false;
    }
    sent += static_cast<size_t>(w);
  }
  return true;
}

bool connect_to_host(int &out_fd) {
  int fd = ::socket(AF_VSOCK, SOCK_STREAM, 0);
  if (fd < 0) {
    perror("socket(AF_VSOCK)");
    return false;
  }

  sockaddr_vm addr {};
  addr.svm_family = AF_VSOCK;
  addr.svm_cid = VMADDR_CID_HOST;
  addr.svm_port = kVsockPort;

  if (::connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
    perror("connect(AF_VSOCK -> host)");
    ::close(fd);
    return false;
  }

  out_fd = fd;
  return true;
}

} // namespace

int main() {
  int sock = -1;
  if (!connect_to_host(sock)) {
    cerr << "[agent] fatal: could not connect to host vsock port " << kVsockPort
         << endl;
    return 1;
  }

  cout << "Connected to honeypot host interceptor (AF_VSOCK)." << endl;

  const string prompt = "root@ubuntu:~# ";

  for (;;) {
    cout << prompt << flush;

    string line;
    if (!getline(cin, line)) {
      // EOF (e.g. session end) — exit cleanly.
      break;
    }

    // Empty line: still round-trip so the LLM can emit a blank line if desired.
    string payload = line;
    payload.push_back('\n');

    if (!send_all(sock, payload.data(), payload.size())) {
      cerr << "[agent] error: failed sending command to host" << endl;
      break;
    }

    uint32_t netlen = 0;
    if (!recv_all(sock, &netlen, sizeof(netlen))) {
      cerr << "[agent] error: host closed connection before response length"
           << endl;
      break;
    }

    const uint32_t resp_len = ntohl(netlen);
    constexpr uint32_t kMaxResponse = 512 * 1024;
    if (resp_len > kMaxResponse) {
      cerr << "[agent] error: response too large (" << resp_len << " bytes)"
           << endl;
      break;
    }

    string response(static_cast<size_t>(resp_len), '\0');
    if (resp_len > 0 && !recv_all(sock, response.data(), resp_len)) {
      cerr << "[agent] error: truncated response body" << endl;
      break;
    }

    cout << response;
    if (!response.empty() && response.back() != '\n') {
      cout << '\n';
    }
    cout << flush;
  }

  ::close(sock);
  return 0;
}
