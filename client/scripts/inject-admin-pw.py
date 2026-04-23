#!/usr/bin/env python3
"""
inject-admin-pw.py — splice the fleet-registration bootstrap into the
upstream RustDesk tree.

On a managed fleet, the admin wants to connect from the admin UI / web
client without ever facing a peer-password prompt. The fork
lejianwen/rustdesk-api exposes exactly what we need:
  - `POST /api/login` → access token
  - `POST /api/ab`    → upsert the peer into the admin's address book,
                        carrying the plaintext peer password.
The admin UI's ljw.js then injects that password into the web client's
localStorage, so `Web Client` opens straight into the session.

On each boot of the Windows service (start_server is_server=true) we:
  1. Generate a random 24-byte peer password if none is configured yet
     and call Config::set_permanent_password().
  2. Lock the UI knobs (disable-change-permanent-password + approve-mode
     = "password") via BUILTIN_SETTINGS / HARD_SETTINGS.
  3. Wipe any runtime override of rendezvous / relay / api / key so a
     future MSI rebrand (new GitHub Secret → new release) actually
     takes effect on the next auto-update.
  4. Log in to the API with the baked-in fleet credentials, GET the
     current address book, and POST back an upserted list only when our
     row is absent or desynchronised (password or alias changed).
     Plaintext password goes into the `password` field, not `hash` —
     we don't have access to the peer's salt at the call site, and the
     ljw.js auto-fill path reads `password`. Self-healing by design: a
     stale client on another machine that wipes our entry (pre
     GET-merge-POST) is repaired on the next reboot of this device.

Why not a git patch? `git apply` silently skips purely-additive patches
when contexts match both pre- and post-patch state ("Skipped patch"
with exit 0). The deterministic string-replace approach here is
idempotent and robust against that.

Called by client/scripts/apply-branding.sh after the .patch loop.
"""

from __future__ import annotations

import pathlib
import sys

UPSTREAM = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "client/upstream")

SERVER_RS = UPSTREAM / "src" / "server.rs"

# ─────────────────────────────────────────────────────────────────────────
# src/server.rs: call the bootstrap from start_server(is_server=true),
# the single entry point every launch path converges on (Windows service
# re-spawns `--server`, Linux daemon, UI spawning its own server thread).
# ─────────────────────────────────────────────────────────────────────────
SERVER_START_ALL_ORIG = (
    "        #[cfg(feature = \"hwcodec\")]\n"
    "        scrap::hwcodec::start_check_process();\n"
    "        crate::RendezvousMediator::start_all().await;\n"
    "    } else {\n"
)
SERVER_START_ALL_NEW = (
    "        #[cfg(feature = \"hwcodec\")]\n"
    "        scrap::hwcodec::start_check_process();\n"
    "        fleet_register_bootstrap();\n"
    "        crate::RendezvousMediator::start_all().await;\n"
    "    } else {\n"
)

SERVER_MODULE = r'''
// ───────────────────────────────────────────────────────────────────────────
// fleet_register — SupportInternal branding.
//
// At the first boot of the Windows service we (a) generate the per-device
// peer password, (b) lock down the UI knobs so the end user can neither
// clear it nor bypass approve-mode=password, (c) wipe any stale runtime
// overrides of the server endpoints so a rebrand actually propagates,
// and (d) upsert this device into the admin's address book via the
// lejianwen /api/login + /api/ab endpoints. The admin UI's ljw.js then
// auto-fills the peer password into the web client's localStorage, so
// clicking "Web Client" no longer prompts.
//
// The four placeholders (__RDC_API_BASE__, __RDC_FLEET_USER__,
// __RDC_FLEET_PASSWORD__, __RDC_BRAND_APP_NAME__) are substituted by
// client/scripts/apply-branding.sh at build time. Unbranded local dev
// builds skip the entire bootstrap (placeholders still start with
// __RDC).
// ───────────────────────────────────────────────────────────────────────────

pub(crate) const FLEET_API_BASE: &str = "__RDC_API_BASE__";
pub(crate) const FLEET_USER: &str = "__RDC_FLEET_USER__";
pub(crate) const FLEET_PASSWORD: &str = "__RDC_FLEET_PASSWORD__";
pub(crate) const FLEET_BRAND: &str = "__RDC_BRAND_APP_NAME__";
pub(crate) const FLEET_VERSION: &str = "__RDC_RELEASE_TAG__";

pub(crate) fn fleet_register_bootstrap() {
    use hbb_common::config::Config;
    if FLEET_API_BASE.starts_with("__RDC") || FLEET_USER.starts_with("__RDC")
        || FLEET_PASSWORD.starts_with("__RDC")
    {
        // apply-branding.sh did not substitute the placeholders (unbranded
        // local dev build) — skip silently.
        return;
    }

    // 1. First-boot password generation. Must happen BEFORE we install the
    //    disable-change-permanent-password lockdown below, because once
    //    that flag is set `set_permanent_password` becomes a no-op.
    let existing = Config::get_permanent_password();
    let password = if existing.is_empty() {
        use hbb_common::rand::RngCore;
        let mut raw = [0u8; 24];
        hbb_common::rand::thread_rng().fill_bytes(&mut raw);
        let pw = crate::common::encode64(raw);
        Config::set_permanent_password(&pw);
        pw
    } else {
        existing
    };

    // 2. Lock the UI knobs.
    {
        use hbb_common::config::{keys, BUILTIN_SETTINGS, HARD_SETTINGS};
        BUILTIN_SETTINGS.write().unwrap().insert(
            keys::OPTION_DISABLE_CHANGE_PERMANENT_PASSWORD.to_string(),
            "Y".to_string(),
        );
        HARD_SETTINGS.write().unwrap().insert(
            keys::OPTION_APPROVE_MODE.to_string(),
            "password".to_string(),
        );
    }

    // 3. Wipe stale runtime overrides so a rebrand via a new MSI actually
    //    takes effect on the next auto-update.
    {
        use hbb_common::config::{keys, Config};
        for k in [
            keys::OPTION_CUSTOM_RENDEZVOUS_SERVER,
            keys::OPTION_API_SERVER,
            keys::OPTION_KEY,
            keys::OPTION_RELAY_SERVER,
        ] {
            if !Config::get_option(k).is_empty() {
                Config::set_option(k.to_string(), String::new());
            }
        }
    }

    // 4. Address-book sync. Self-healing: runs on every service boot,
    //    GETs the current AB, and only POSTs when our row is absent or
    //    desynchronised (password or alias changed). A stale client on
    //    another machine that wipes our entry (pre GET-merge-POST) is
    //    thus repaired on the next reboot of this device. The local
    //    `fleet_registered` flag is informational only — it no longer
    //    gates the call. Wrapped in catch_unwind so a network failure
    //    never kills the service thread.
    let device_id = Config::get_id();
    if device_id.is_empty() {
        return;
    }
    std::thread::spawn(move || {
        let _ = std::panic::catch_unwind(|| {
            if let Err(e) = fleet_register_call(&device_id, &password) {
                log::warn!("fleet_register: {}", e);
            }
        });
    });
}

fn fleet_register_call(device_id: &str, password: &str) -> hbb_common::ResultType<()> {
    use std::time::Duration;

    let hostname = hbb_common::whoami::fallible::hostname().unwrap_or_else(|_| "unknown".to_string());
    let platform = if cfg!(target_os = "windows") {
        "Windows"
    } else if cfg!(target_os = "macos") {
        "Mac OS"
    } else {
        "Linux"
    };

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .danger_accept_invalid_certs(true)
        .build()?;

    // 4a. Login with the fleet account baked into the binary.
    let login_body = serde_json::json!({
        "username": FLEET_USER,
        "password": FLEET_PASSWORD,
        "id": device_id,
        "uuid": crate::common::encode64(device_id.as_bytes()),
        "autoLogin": true,
        "type": "account",
        "deviceInfo": { "name": hostname.clone(), "os": platform.to_lowercase(), "type": "" },
    });
    let login_url = format!("{}/api/login", FLEET_API_BASE.trim_end_matches('/'));
    let login_resp = client.post(&login_url).json(&login_body).send()?;
    let st = login_resp.status();
    if !st.is_success() {
        let body = login_resp.text().unwrap_or_default();
        hbb_common::bail!("fleet login: HTTP {} {}", st, body);
    }
    let login_json: serde_json::Value = login_resp.json()?;
    let token = login_json
        .get("access_token")
        .and_then(|v| v.as_str())
        .ok_or_else(|| hbb_common::anyhow::anyhow!("no access_token in login response"))?
        .to_string();

    // 4b. Fetch the existing AB; decide if we need to POST.
    //     /api/ab is a REPLACE endpoint (overwrites the full peer list)
    //     not an upsert — calling it with {peers:[us]} would wipe every
    //     other fleet-registered device. Read-modify-write is racy across
    //     simultaneous first-boots, but first-boot is rare and retries
    //     are idempotent, so it's acceptable in practice. Plaintext
    //     password goes into the `password` field (ljw.js consumes it
    //     directly).
    //
    //     Alias carries the MSI release tag (e.g. "SupportInternal v0.0.26 ·
    //     11685147") — Windows Installer's ICE24 forbids the same metadata
    //     in Cargo.toml's version string, so it rides along here where the
    //     admin UI renders it in the address-book list anyway.
    let alias = if FLEET_VERSION.is_empty() || FLEET_VERSION.starts_with("__RDC") {
        format!("{} · {}", FLEET_BRAND, device_id)
    } else {
        format!("{} {} · {}", FLEET_BRAND, FLEET_VERSION, device_id)
    };

    let ab_url = format!("{}/api/ab", FLEET_API_BASE.trim_end_matches('/'));
    let get_resp = client.get(&ab_url).bearer_auth(&token).send()?;
    let mut tags = serde_json::Value::Array(vec![]);
    let mut tag_colors = serde_json::Value::String(String::from("{}"));
    let mut peers_other: Vec<serde_json::Value> = Vec::new();
    let mut existing_self: Option<serde_json::Value> = None;
    if get_resp.status().is_success() {
        if let Ok(env) = get_resp.json::<serde_json::Value>() {
            if let Some(raw) = env.get("data").and_then(|v| v.as_str()) {
                if let Ok(inner) = serde_json::from_str::<serde_json::Value>(raw) {
                    if let Some(arr) = inner.get("peers").and_then(|v| v.as_array()) {
                        for p in arr {
                            if p.get("id").and_then(|v| v.as_str()) == Some(device_id) {
                                existing_self = Some(p.clone());
                            } else {
                                peers_other.push(p.clone());
                            }
                        }
                    }
                    if let Some(t) = inner.get("tags").cloned() {
                        tags = t;
                    }
                    if let Some(tc) = inner.get("tag_colors").cloned() {
                        tag_colors = tc;
                    }
                }
            }
        }
    }

    // Server-side idempotency: skip the POST when the AB already has us
    // with the current password and alias. Avoids needless churn on every
    // service boot. If either field drifted (password rotated on the
    // client, release tag bumped on the binary, or admin edited the row),
    // we fall through to the POST and resync.
    if let Some(self_row) = existing_self.as_ref() {
        let pw_ok = self_row
            .get("password")
            .and_then(|v| v.as_str())
            .map(|s| s == password)
            .unwrap_or(false);
        let alias_ok = self_row
            .get("alias")
            .and_then(|v| v.as_str())
            .map(|s| s == alias)
            .unwrap_or(false);
        if pw_ok && alias_ok {
            hbb_common::config::Config::set_option(
                "fleet_registered".to_string(),
                "Y".to_string(),
            );
            log::info!("fleet_register: already in sync (id={})", device_id);
            return Ok(());
        }
    }

    let mut peers_out = peers_other;
    peers_out.push(serde_json::json!({
        "id": device_id,
        "username": "",
        "hostname": hostname,
        "platform": platform,
        "alias": alias,
        "tags": [],
        "password": password,
        "hash": "",
    }));
    let ab_data = serde_json::json!({
        "tags": tags,
        "peers": peers_out,
        "tag_colors": tag_colors,
    })
    .to_string();
    let ab_body = serde_json::json!({ "data": ab_data });
    let ab_resp = client
        .post(&ab_url)
        .bearer_auth(&token)
        .json(&ab_body)
        .send()?;
    let st = ab_resp.status();
    if !st.is_success() {
        let body = ab_resp.text().unwrap_or_default();
        hbb_common::bail!("fleet ab upsert: HTTP {} {}", st, body);
    }

    hbb_common::config::Config::set_option(
        "fleet_registered".to_string(),
        "Y".to_string(),
    );
    log::info!("fleet_register: synced (id={})", device_id);
    Ok(())
}
'''


def _apply_once(path: pathlib.Path, orig: str, new: str, sentinel: str) -> str:
    content = path.read_text(encoding="utf-8")
    if sentinel in content:
        return "already applied"
    if orig not in content:
        raise SystemExit(
            f"[inject-fleet-register] ERROR: expected anchor not found in {path}\n"
            f"Did client/upstream drift from the pinned version?\n"
            f"First line of the anchor:\n  {orig.splitlines()[0]!r}"
        )
    path.write_text(encoding="utf-8", data=content.replace(orig, new, 1))
    return "applied"


def main() -> None:
    if not SERVER_RS.is_file():
        raise SystemExit(f"[inject-fleet-register] ERROR: missing {SERVER_RS}")

    # 1. Wire the call into start_server's service branch.
    print(
        f"[inject-fleet-register] server.rs call: "
        f"{_apply_once(SERVER_RS, SERVER_START_ALL_ORIG, SERVER_START_ALL_NEW, 'fleet_register_bootstrap();')}"
    )

    # 2. Append the bootstrap module at the end of the file.
    content = SERVER_RS.read_text(encoding="utf-8")
    if "fn fleet_register_bootstrap()" in content:
        print("[inject-fleet-register] server.rs module: already applied")
    else:
        SERVER_RS.write_text(encoding="utf-8", data=content.rstrip() + "\n" + SERVER_MODULE)
        print("[inject-fleet-register] server.rs module: applied")


if __name__ == "__main__":
    main()
