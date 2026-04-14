# The Petridish — one-pager

## Problem

Static honeypots are easy to fingerprint and do not scale believable attacker interactions.

## Solution

A **Firecracker microVM** exposes a fake shell. Each command is sent to the **host over vsock**, answered by a **local LLM (Ollama)** with plausible terminal output, and logged as **structured telemetry** for a **Streamlit SOC-style console**.

## Why it is compelling

- **Isolation-first**: default path avoids guest networking; attacker surface is controlled.
- **Dynamic**: responses adapt to arbitrary command lines via LLM synthesis.
- **Observable**: JSONL + live dashboard + CSV export for evidence and storytelling.

## Stack

Firecracker, Linux vsock, Python (`requests`), Ollama, Streamlit, pandas.

## Limitations (be explicit)

Prototype scope: single-session assumptions, local-only LLM endpoint, no built-in enterprise RBAC/SIEM.

## Future work

Multi-session orchestration, SIEM connectors, richer detection taxonomy, formal evaluations of model output safety.
