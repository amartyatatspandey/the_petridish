# Evidence appendix (fill in before submission)

Use this as a checklist for portfolio or grading packets.

## Repository

- **GitHub URL:** `https://github.com/<org>/<repo>`
- **Default branch:** `main`
- **Demo tag (optional):** `v0.1-demo`

## CI

- Paste link to the latest **green** GitHub Actions run for `CI` workflow.

## Screenshots (recommended)

1. Streamlit SOC console showing live rows and latency chart.
2. Terminal showing successful `./honeypot-project/test_run.sh` startup lines.
3. Optional: guest side interaction (serial console) with host response.

## Commands executed (template)

```text
cd honeypot-project
./infra/01_setup_firecracker.sh
sudo ./infra/02_build_rootfs.sh
ollama pull llama3.2
ollama serve   # separate terminal
./test_run.sh
```

## Sample offline demo

```text
streamlit run honeypot-project/analytics/dashboard.py
# In UI sidebar: Sample (offline demo)
```

## Notes

- macOS cannot build the vsock guest agent; validate on Linux or WSL2 per `docs/KNOWN_ISSUES.md`.
