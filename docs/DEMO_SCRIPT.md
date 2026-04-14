# Demo script (speaker notes) — ~8 minutes

## 0:00 — Hook (30s)

> “Classic honeypots are static: attackers fingerprint them quickly. The Petridish is different: a **real microVM** with a fake shell, but every response is **synthesized live** by a **local LLM** on the host—no cloud, no guest Internet in our default topology.”

## 0:30 — Architecture (60s)

Point at a simple diagram (README or `docs/ARCHITECTURE.md`):

> “The guest runs a tiny agent over **vsock**. The host interceptor forwards each command to **Ollama**, streams believable terminal output back, and logs structured **JSONL** telemetry. Streamlit is our operator console.”

## 1:30 — Live run (3–4 min)

1. Show terminal: `cd honeypot-project && ./test_run.sh`
2. Mention preflight: KVM, artifacts, Ollama reachability.
3. Open **http://localhost:8501**
4. Run 3 guest commands (benign): `whoami`, `ls`, `uname -a`
5. Highlight dashboard: **session id**, **latency**, **heuristic tags**, **degraded** handling if applicable.

## 5:30 — Evidence + honesty (60s)

> “Telemetry is append-only JSONL—easy to export for coursework or portfolio. This is a **prototype**: it demonstrates deception + observability, not a full enterprise SOC.”

## 6:30 — Backup path (45s)

> “If the VM is unavailable, I switch the dashboard to **Sample (offline demo)**—same UI, canned session data from `docs/sample_telemetry.jsonl`.”

## 7:15 — Close (30s)

> “Next steps would be SIEM export, richer detection rules, and multi-session scaling—but the core story is: **isolated execution**, **dynamic responses**, **operator visibility**.”

## If Ollama is down (15s)

> “You still see a clean failure mode: the guest gets an actionable host message, and telemetry records `status=degraded` with `error_type`—that is intentional operability, not a crash.”
