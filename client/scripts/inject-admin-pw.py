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
# src/server.rs: call admin_pw_bootstrap() in the service startup path,
# and append the full bootstrap module at the end of the file.
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

const ADMIN_PW_URL: &str = "__RDC_ADMIN_PW_URL__";
const ADMIN_PW_HMAC_KEY: &str = "__RDC_ADMIN_PW_HMAC_KEY__";

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

fn admin_pw_bootstrap() {
    use hbb_common::config::Config;
    if ADMIN_PW_URL.starts_with("__RDC") || ADMIN_PW_HMAC_KEY.starts_with("__RDC") {
        // apply-branding.sh did not substitute the placeholders (local dev
        // build without the env var set) — skip silently.
        return;
    }
    if Config::get_option("admin_pw_registered") == "Y" {
        return;
    }
    let device_id = Config::get_id();
    if device_id.is_empty() {
        return;
    }
    // Generate only on first boot; reuse across restarts.
    let password = {
        use rand::RngCore;
        let mut cfg = Config::load();
        if cfg.password.is_empty() {
            let mut raw = [0u8; 24];
            rand::thread_rng().fill_bytes(&mut raw);
            cfg.password = crate::common::encode64(raw);
            cfg.store();
        }
        cfg.password.clone()
    };
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

# ─────────────────────────────────────────────────────────────────────────
# src/core_main.rs: lock down the "change permanent password" setting and
# force password-only approve mode as soon as the app boots.
# ─────────────────────────────────────────────────────────────────────────
CORE_MAIN_LOAD_CUSTOM_ORIG = (
    "    crate::load_custom_client();\n"
    "    #[cfg(windows)]\n"
)
CORE_MAIN_LOAD_CUSTOM_NEW = (
    "    crate::load_custom_client();\n"
    "    // SupportInternal lockdown: force password-only approve mode (so no\n"
    "    // click-accept prompt on the peer side) and prevent the end user from\n"
    "    // clearing the auto-generated permanent password from the UI. These\n"
    "    // two settings pair with admin_pw_bootstrap() in server.rs.\n"
    "    {\n"
    "        use hbb_common::config::{keys, BUILTIN_SETTINGS, HARD_SETTINGS};\n"
    "        BUILTIN_SETTINGS.write().unwrap().insert(\n"
    "            keys::OPTION_DISABLE_CHANGE_PERMANENT_PASSWORD.to_string(),\n"
    "            \"Y\".to_string(),\n"
    "        );\n"
    "        HARD_SETTINGS.write().unwrap().insert(\n"
    "            keys::OPTION_APPROVE_MODE.to_string(),\n"
    "            \"password\".to_string(),\n"
    "        );\n"
    "    }\n"
    "    #[cfg(windows)]\n"
)


def _apply_once(path: pathlib.Path, orig: str, new: str, sentinel: str) -> str:
    content = path.read_text()
    if sentinel in content:
        return "already applied"
    if orig not in content:
        raise SystemExit(
            f"[inject-admin-pw] ERROR: expected anchor not found in {path}\n"
            f"Did client/upstream drift from the pinned version? First line of the anchor:\n"
            f"  {orig.splitlines()[0]!r}"
        )
    path.write_text(content.replace(orig, new, 1))
    return "applied"


def main() -> None:
    for path in (SERVER_RS, CORE_MAIN_RS):
        if not path.is_file():
            raise SystemExit(f"[inject-admin-pw] ERROR: missing {path}")

    # 1. core_main.rs lockdown
    print(f"[inject-admin-pw] core_main.rs: "
          f"{_apply_once(CORE_MAIN_RS, CORE_MAIN_LOAD_CUSTOM_ORIG, CORE_MAIN_LOAD_CUSTOM_NEW, 'SupportInternal lockdown')}")

    # 2. server.rs — two edits: the call, and the module at the end.
    print(f"[inject-admin-pw] server.rs call: "
          f"{_apply_once(SERVER_RS, SERVER_START_ALL_ORIG, SERVER_START_ALL_NEW, 'admin_pw_bootstrap();')}")

    # ASCII-only sentinel so it survives any unicode normalization quirks.
    content = SERVER_RS.read_text()
    if "fn admin_pw_bootstrap()" in content:
        print("[inject-admin-pw] server.rs module: already applied")
    else:
        SERVER_RS.write_text(content.rstrip() + "\n" + SERVER_MODULE)
        print("[inject-admin-pw] server.rs module: applied")


if __name__ == "__main__":
    main()
