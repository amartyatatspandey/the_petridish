# Security and responsible use

## What this project is

A **research and education** honeypot prototype: it simulates a vulnerable shell session using a **local LLM** and logs interaction telemetry for operator review.

## Non-goals

- This is **not** a production SOC platform, IDS, or managed deception service.
- It does **not** provide multi-tenant isolation, strong authentication, or enterprise compliance controls out of the box.

## Data handling

- Telemetry may contain **arbitrary attacker-controlled strings** (commands and model output). Treat logs as **untrusted input**.
- Decide **retention**, **encryption at rest**, and **access control** for `honeypot-project/logs/telemetry.json` before operating outside a lab.
- Do not commit real production telemetry to public repositories.

## Model output

- Prompting aims for **fictional plausible** terminal transcripts and avoids real third-party exploit recipes. Model behavior can still drift; **review outputs** before sharing screenshots publicly.

## Deployment guidance

- Run Ollama and the interceptor on **trusted networks** only.
- Do not expose the Streamlit server or interceptor sockets to the public Internet without hardening (TLS, auth, firewall rules).
- Ensure **legal and policy approval** before deploying honeypots on any network you do not own outright.

## Reporting issues

If you discover a security defect in this repository’s code, report it privately to the repository maintainers.
