# MailHub

[中文](README.md) · [English](README.en.md)

Bring several IMAP accounts into one inbox. MailHub collects remote mail with Fetchmail, stores it in Stalwart and exposes a unified Bulwark webmail interface for reading, searching and managing a personal self-hosted mailbox.

## Features

- Multi-account collection: per-account IMAP configuration, ongoing delivery and optional initial history import.
- Unified mailbox: the collector delivers over internal SMTP to Stalwart, managed through one webmail UI.
- Bootstrap configuration for mailbox identity, administrators, collector trust and timeouts.
- Spam feedback: training services and rule-update entry points for classification feedback.
- Optional integrations: Authentik/OIDC sign-in and SMTP relay settings.
- Persistent deployment: Docker Compose manages services while mail and account configuration stay in the chosen host directory.

## Quick start

Docker Engine with Compose, remote IMAP accounts, and a domain with an HTTPS reverse proxy for webmail.

```sh
cp .env.example .env
cp accounts/custom.example.env accounts/personal.env
# Fill .env and the account file before starting.
docker compose up -d --build
docker compose ps
```

## Configuration

| Setting | Purpose |
| --- | --- |
| `DATA_ROOT` | Root directory for mail and service data. |
| `MAIL_HUB_HOSTNAME / HUB_DOMAIN` | Public service hostname and local mailbox domain. |
| `STALWART_ADMIN_PASSWORD` | Stalwart administrator password. |
| `BULWARK_SESSION_SECRET` | Independent random webmail session secret. |
| `accounts/*.env` | Remote mailbox addresses, server details and credentials. |
| `MAIL_HUB_OIDC_*` | Optional OIDC settings; the identity claim must map to the local mailbox. |

## Usage

After configuration, open webmail through the reverse proxy. Collection defaults to new mail; check each account’s initial full-import setting when migrating older messages. `compose.yaml` defines the service ports and forwarding relationships.

## Project structure

- `collector/` — Mail collection
- `stalwart/` — Mail service and bootstrap
- `bulwark/` — Webmail configuration
- `trainer/` — Spam training

## License

[PolyForm Noncommercial 1.0.0](LICENSE). See [LICENSE_SCOPE.md](LICENSE_SCOPE.md) for the scope of original material and third-party components, and the accompanying notices for third-party copyrights and licenses.
