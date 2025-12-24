# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cloudflare Origin CA certificate management tool v2.0. Supports multiple domains with independent configuration and scheduling. Creates and renews SSL certificates via Cloudflare API.

## Dependencies

```bash
uv sync
source .venv/bin/activate
```

Key dependencies managed by `pyproject.toml`: `requests`, `pyyaml`

## Commands

- Run interactive setup wizard:
  ```bash
  sudo ./setup_certificate.sh           # First-time setup
  sudo ./setup_certificate.sh --add-domain   # Add new domain
  ./setup_certificate.sh --list              # List configured domains
  ```

- Create/renew certificates:
  ```bash
  python cert_manager.py --domain example.com    # Single domain
  python cert_manager.py                          # All domains
  ```

- Update certificates via shell script:
  ```bash
  ./update_certificate.sh --domain example.com   # Single domain
  ./update_certificate.sh --all                   # All domains
  ```

## Architecture

Three main components:

1. **`cert_manager.py`** - Core Python module with:
   - `ConfigLoader` - Loads YAML configuration, supports domain-specific overrides
   - `CloudflareAPI` - API calls to Cloudflare (`POST /certificates`)
   - Certificate operations: CSR generation, fingerprint calculation, file saving

2. **`update_certificate.sh`** - Shell wrapper that:
   - Reads configuration from `config.yaml`
   - Updates single or all domains
   - Logs to `/var/log/cert_update.log`

3. **`setup_certificate.sh`** - Interactive bash wizard:
   - Initial setup: creates `config.yaml` with global defaults
   - `add-domain`: adds new domain configuration
   - Supports Zone ID auto-fetch via API token

## Certificate Storage

```
/etc/cert/
└── {domain}/
    └── {hostname}/
        ├── {domain}.{hostname}.crt
        ├── {domain}.{hostname}.key
        └── {domain}.{hostname}.fingerprint
```

## Configuration

Configuration file: `config.yaml` (gitignored)

Template: `config.example.yaml`

```yaml
default:
  origin_ca_key: "your-origin-ca-key"  # Global default
  cert_type: "origin-rsa"
  validity_days: 90
  base_cert_dir: "/etc/cert"

domains:
  example.com:
    hostnames:
      - www.example.com
      - api.example.com
    enable_cron: true
```

Each domain can override global defaults with its own settings.
