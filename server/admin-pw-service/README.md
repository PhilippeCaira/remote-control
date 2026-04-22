# admin-pw-service

Tiny sidecar that persists per-device peer passwords so branded
SupportInternal clients can be remote-controlled from the admin UI
without the end user ever seeing or setting a password.

## Flow

1. A fresh client at first boot of its Windows service generates a
   random 24-byte password, writes it to its local `Config::password`,
   and `POST`s it here signed with the shared HMAC key that was baked
   into the binary at build time.
2. The sidecar stores the password in SQLite, keyed by the device's
   RustDesk ID.
3. When the human admin clicks "Connect" on that device in the admin UI
   (or uses the companion `/admin-pw/ui` page), the password is fetched
   from here with a JWT signed by `RUSTDESK_API_JWT_KEY` — the same
   secret `rustdesk-api` already uses — and pasted into the prompt.

## Endpoints

| Method | Path                      | Auth             | Purpose                       |
|--------|---------------------------|------------------|-------------------------------|
| POST   | `/admin-pw/{device_id}`   | HMAC-SHA256      | Client registers its password |
| GET    | `/admin-pw/{device_id}`   | Bearer JWT       | Admin fetches the password    |
| DELETE | `/admin-pw/{device_id}`   | Bearer JWT       | Admin revokes / frees the slot|
| GET    | `/healthz`                | none             | Docker healthcheck            |

### POST body

```json
{
  "password": "<base64>",
  "ts":       <unix-seconds>,
  "hmac":     "<hex>"
}
```

`hmac = HMAC-SHA256(ADMIN_PW_HMAC_KEY, "{device_id}:{password}:{ts}")`.

The timestamp must be within 300 s of the server clock. Once any admin
`GET`s the password the row is marked `onboarded=0`; further `POST`s
are refused with 409 until a `DELETE` frees the slot. This blocks a
compromised HMAC key from silently overwriting a registered device.

## Env contract

| Variable                    | Required | Purpose                                       |
|-----------------------------|----------|-----------------------------------------------|
| `ADMIN_PW_HMAC_KEY`         | yes      | Shared with the client binary (build secret). |
| `ADMIN_PW_JWT_KEY`          | yes      | Same as `RUSTDESK_API_JWT_KEY` — reused.      |
| `ADMIN_PW_HMAC_KEY_PREV`    | no       | Old key accepted during rotation windows.     |
| `ADMIN_PW_ALLOW_REREGISTER` | no       | `1` = accept POST overwrites (recovery only). |
| `ADMIN_PW_DB_PATH`          | no       | SQLite file path, default `/data/admin-pw.db`.|

## Local development

```bash
pip install -r requirements.txt
ADMIN_PW_HMAC_KEY=dev-hmac \
  ADMIN_PW_JWT_KEY=dev-jwt \
  ADMIN_PW_DB_PATH=/tmp/admin-pw.db \
  uvicorn main:app --reload
```

## Tests

```bash
pytest -q
```

Tests cover the happy path, HMAC rejection, timestamp skew, anti-takeover,
JWT rejection, and DELETE + re-register.
