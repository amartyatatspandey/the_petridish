# Known issues and platform notes

## macOS (Darwin)

- The guest agent includes **Linux vsock headers** (`linux/vm_sockets.h`). Building `guest-agent` natively on macOS **fails** — this is expected. Use **Linux** or **WSL2** for full stack builds and Firecracker.
- Firecracker requires **KVM** (`/dev/kvm`), which is not available on macOS hosts.

## Windows

- Run the project from **WSL2 Ubuntu**, not PowerShell alone. See [WINDOWS_WSL_TESTING.md](WINDOWS_WSL_TESTING.md).

## WSL2

- `/dev/kvm` may be missing until **nested virtualization** is enabled for the WSL VM in Windows settings.
- If Ollama runs on **Windows** and the interceptor runs in **WSL**, `localhost:11434` may not reach Windows from WSL depending on networking mode. Prefer **Ollama inside the same WSL distro** as the interceptor.

## Architecture naming

- `uname -m` may report `arm64` on Apple Silicon macOS while Linux scripts expect `aarch64` for some paths — irrelevant on macOS for this stack; use Linux/WSL for execution.

## Streamlit port

- Default **8501** may conflict with other apps. Stop conflicting services or change Streamlit’s port in your launch command.
