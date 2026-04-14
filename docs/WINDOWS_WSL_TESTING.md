# Windows/WSL Testing Guide

This project is designed to run from Linux userland. On a Windows laptop, run it from WSL2 (Ubuntu), not from PowerShell alone.

## 1) One-time setup on Windows

1. Enable virtualization in BIOS/UEFI.
2. Install WSL2 and Ubuntu.
3. In Ubuntu, install dependencies:

```bash
sudo apt update
sudo apt install -y build-essential python3 python3-pip python3-venv curl git util-linux qemu-kvm cpu-checker
```

4. Validate KVM and group permissions:

```bash
kvm-ok
sudo usermod -aG kvm "$USER"
newgrp kvm
```

If `/dev/kvm` does not appear in WSL, enable nested virtualization for WSL2 in Windows and restart WSL.

## 2) Get the repository

```bash
cd ~
git clone https://github.com/amartyatatspandey/the_petridish.git
cd the_petridish/honeypot-project
```

## 3) Install Python requirements

```bash
python3 -m pip install --user -r host-interceptor/requirements.txt
```

## 4) Start Ollama in WSL

The interceptor expects `http://localhost:11434` in the same environment.

```bash
ollama serve
```

In another shell:

```bash
ollama pull llama3.2
```

## 5) One-time Firecracker/rootfs prep

```bash
./infra/01_setup_firecracker.sh
sudo ./infra/02_build_rootfs.sh
```

## 6) Run the full demo

From the **repository root** (parent of `honeypot-project/`), optional but recommended:

```bash
./scripts/demo/preflight.sh
```

Then:

```bash
cd honeypot-project
./test_run.sh
```

Open `http://localhost:8501` from Windows browser for the dashboard.

## 7) Success criteria

- `test_run.sh` starts Streamlit, interceptor, and VM launch flow without early fatal errors.
- `logs/telemetry.json` receives rows as commands are processed.
- Dashboard metric and table update live.

## 8) Common issues

- **`/dev/kvm` missing or permission denied:** fix nested virtualization and `kvm` group setup.
- **`Could not reach local Ollama`:** start `ollama serve` in the same WSL distro/session.
- **Streamlit not reachable on Windows:** verify the URL printed by Streamlit and local firewall rules.
