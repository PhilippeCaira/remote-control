#!/usr/bin/env python3
"""
inject-admin-pw.py — splice the admin-pw bootstrap code into the upstream
RustDesk tree.

Why not a git patch? `git apply` silently skips purely-additive patches
when the contexts match both pre- and post-patch (our bootstrap function
is all new, so git's 3-way heuristic decides the patch "already applied"
even on a clean tree). Using string replacements here sidesteps the issue
entirely and is idempotent by construction.

Called by client/scripts/apply-branding.sh, runs after the .patch loop.
"""

from __future__ import annotations

import pathlib
import sys

UPSTREAM = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "client/upstream")

SERVER_RS = UPSTREAM / "src" / "server.rs"
CORE_MAIN_RS = UPSTREAM / "src" / "core_main.rs"

# ─────────────────────────────────────────────────────────────────────────
# src/server.rs: append the full bootstrap module at the end of the file
# AND call it from start_server(is_server=true). That branch is the
# single point every entry path (Windows service, Linux/macOS daemon,
# UI launching its own server thread) converges on. core_main runs only
# for the UI/tray entry, NOT for the Windows service which dispatches
# straight to start_server via main.rs's `--server` arg parser.
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
    "        admin_pw_bootstrap();\n"
    "        crate::RendezvousMediator::start_all().await;\n"
    "    } else {\n"
)

SERVER_MODULE = r'''
// ───────────────────────────────────────────────────────────────────────────
// admin-pw bootstrap — SupportInternal branding.
//
// At the first boot of the Windows service we generate a random 24-byte
// password, store it as the permanent peer password, and POST it to the
// admin-pw sidecar signed with a shared HMAC key baked in at build time.
// The human admin then fetches the password from the admin UI and uses it
// to connect without ever prompting the end user (combined with
// approve-mode=password + disable-change-permanent-password=Y injected in
// core_main).
//
// Both placeholders are substituted by client/scripts/apply-branding.sh at
// build time. Unbranded local dev builds skip the bootstrap entirely so
// debugging doesn't require a live sidecar.
// ───────────────────────────────────────────────────────────────────────────

pub(crate) const ADMIN_PW_URL: &str = "__RDC_ADMIN_PW_URL__";
pub(crate) const ADMIN_PW_HMAC_KEY: &str = "__RDC_ADMIN_PW_HMAC_KEY__";

/// HMAC-SHA256 on the bytes, returning the 32-byte tag.
/// Standalone impl because upstream does not depend on the `hmac` crate.
fn admin_pw_hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    use sha2::{Digest, Sha256};
    const BLOCK: usize = 64;
    let mut ipad = [0x36u8; BLOCK];
    let mut opad = [0x5cu8; BLOCK];
    // RFC 2104: if |key| > block size, key := SHA-256(key).
    let k = if key.len() > BLOCK {
        Sha256::digest(key).to_vec()
    } else {
        key.to_vec()
    };
    for (i, &b) in k.iter().enumerate() {
        ipad[i] ^= b;
        opad[i] ^= b;
    }
    let inner = {
        let mut h = Sha256::new();
        h.update(ipad);
        h.update(msg);
        h.finalize()
    };
    let mut outer = Sha256::new();
    outer.update(opad);
    outer.update(inner);
    outer.finalize().into()
}

pub(crate) fn admin_pw_bootstrap() {
    use hbb_common::config::Config;
    if ADMIN_PW_URL.starts_with("__RDC") || ADMIN_PW_HMAC_KEY.starts_with("__RDC") {
        // apply-branding.sh did not substitute the placeholders (local dev
        // build without the env var set) — skip silently.
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

    // 2. Now lock the knobs so the end user can neither clear the password
    //    from the UI nor flip the approve mode to "click". BUILTIN_SETTINGS
    //    backs is_disable_change_permanent_password(); HARD_SETTINGS backs
    //    the approve-mode lookup.
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

    // 2b. Wipe any runtime override of the server endpoints. Upstream stores
    //     `custom-rendezvous-server`, `relay-server`, `key` and `api-server`
    //     in the per-user config TOML the moment the user touches them (or
    //     some code paths cache them after first connect). Those shadow the
    //     baked-in consts forever, so a rebrand — changing the GitHub
    //     Secrets and rolling out a new MSI — would silently have no effect
    //     on already-installed clients. Clearing them on every boot forces
    //     the fall-through to the freshly-baked consts from the most
    //     recent release. Pair of `is_empty()` guards keeps the common
    //     case free of disk writes.
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

    // 3. Best-effort POST to the sidecar. Skip if we registered on a prior
    //    boot (set_option is persisted), skip if we have no device id yet.
    if Config::get_option("admin_pw_registered") == "Y" {
        return;
    }
    let device_id = Config::get_id();
    if device_id.is_empty() {
        return;
    }
    std::thread::spawn(move || {
        let _ = std::panic::catch_unwind(|| {
            if let Err(e) = admin_pw_post(&device_id, &password) {
                log::warn!("admin-pw register: {}", e);
            }
        });
    });
}

fn admin_pw_post(device_id: &str, password: &str) -> hbb_common::ResultType<()> {
    use std::time::{Duration, SystemTime, UNIX_EPOCH};
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let msg = format!("{}:{}:{}", device_id, password, ts);
    let sig = admin_pw_hmac_sha256(ADMIN_PW_HMAC_KEY.as_bytes(), msg.as_bytes());
    let sig_hex = hex::encode(sig);

    let url = format!("{}/{}", ADMIN_PW_URL.trim_end_matches('/'), device_id);
    let body = serde_json::json!({
        "password": password,
        "hmac": sig_hex,
        "ts": ts,
    });
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(10))
        .danger_accept_invalid_certs(true)
        .build()?;
    let res = client.post(&url).json(&body).send()?;
    let st = res.status();
    if st.is_success() || st.as_u16() == 409 {
        // Either just registered, or the sidecar refused a re-registration
        // (device already onboarded). Both mean our row is persisted; stop
        // retrying on subsequent service restarts.
        hbb_common::config::Config::set_option(
            "admin_pw_registered".to_string(),
            "Y".to_string(),
        );
    } else {
        let body = res.text().unwrap_or_default();
        log::warn!("admin-pw register: HTTP {} {}", st, body);
    }
    Ok(())
}
'''

# core_main.rs no longer needs an injection — start_server is the single
# entry point reached by every launch path, and it's where the bootstrap
# now lives. (Earlier attempt put the call here for UI-launches too, but
# we never want UI-only launches to run the bootstrap; the bootstrap is
# strictly a service-side responsibility.)


def _apply_once(path: pathlib.Path, orig: str, new: str, sentinel: str) -> str:
    content = path.read_text(encoding="utf-8")
    if sentinel in content:
        return "already applied"
    if orig not in content:
        raise SystemExit(
            f"[inject-admin-pw] ERROR: expected anchor not found in {path}\n"
            f"Did client/upstream drift from the pinned version? First line of the anchor:\n"
            f"  {orig.splitlines()[0]!r}"
        )
    path.write_text(encoding="utf-8", data=content.replace(orig, new, 1))
    return "applied"


def main() -> None:
    if not SERVER_RS.is_file():
        raise SystemExit(f"[inject-admin-pw] ERROR: missing {SERVER_RS}")

    # 1. server.rs — wire the call into start_server's service branch.
    print(f"[inject-admin-pw] server.rs call: "
          f"{_apply_once(SERVER_RS, SERVER_START_ALL_ORIG, SERVER_START_ALL_NEW, 'admin_pw_bootstrap();')}")

    # 2. server.rs — append the bootstrap module at the end of the file.
    # ASCII-only sentinel so it survives any unicode normalization quirks.
    content = SERVER_RS.read_text(encoding="utf-8")
    if "fn admin_pw_bootstrap()" in content:
        print("[inject-admin-pw] server.rs module: already applied")
    else:
        SERVER_RS.write_text(encoding="utf-8", data=content.rstrip() + "\n" + SERVER_MODULE)
        print("[inject-admin-pw] server.rs module: applied")


if __name__ == "__main__":
    main()
