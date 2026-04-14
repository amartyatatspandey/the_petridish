# Demo checklist — The Petridish

Use this before a presentation, interview, or class demo.

## One day before

- [ ] Pull latest `main` (or your tagged demo commit).
- [ ] On a **Linux or WSL2 Ubuntu** machine with `/dev/kvm` working, run `honeypot-project/infra/01_setup_firecracker.sh` once if binaries are missing.
- [ ] Run `sudo honeypot-project/infra/02_build_rootfs.sh` if `rootfs.ext4` is missing or stale.
- [ ] `ollama pull llama3.2` (or the model you configured).
- [ ] Record a **2-minute screen capture** of a successful run as backup.

## 30 minutes before

- [ ] Close other Streamlit apps using port **8501**.
- [ ] Start `ollama serve` in the **same environment** where `interceptor.py` will run.
- [ ] From repo root: `./scripts/demo/preflight.sh` (or rely on `test_run.sh`, which runs it automatically).
- [ ] `pip install -r honeypot-project/host-interceptor/requirements.txt` if needed.

## Live demo flow

1. Terminal: `cd honeypot-project && ./test_run.sh`
2. Browser: open **http://localhost:8501**
3. In the guest console (serial / your attach path), type a few benign commands (`whoami`, `ls`, `uname -a`).
4. Point audience at dashboard: **commands**, **latency**, **tags**, **session filter**.

## If telemetry stays empty

- Confirm the guest agent connected (interceptor logs `guest connected`).
- Confirm `honeypot-project/logs/telemetry.json` is growing.
- Fall back: Streamlit sidebar → **Sample (offline demo)** and narrate from `docs/sample_telemetry.jsonl`.

## If Ollama fails mid-demo

- Narrate the **degraded** row in telemetry (`status=degraded`, `error_type=ollama_unreachable`).
- Restart `ollama serve` and retry one command.

## After demo

- Press **Ctrl+C** in the terminal running `test_run.sh` (tears down Streamlit, interceptor, Firecracker).
