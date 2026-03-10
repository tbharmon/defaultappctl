# DefaultAppCtl

**DefaultAppCtl** is a macOS command-line tool for applying default application handler mappings for:

- **URL schemes** (e.g., `http`, `mailto`, `webcal`)
- **UTType / UTI identifiers** (e.g., `com.adobe.pdf`, `public.html`)

It is designed for enterprise deployment via a **signed PKG** and supports execution in both:

- **root context** (e.g., PKG `postinstall`)
- **logged-in user GUI context** (required for reliable per-user LaunchServices defaults)

To make user‑context execution reliable and support delayed application installs, this project also includes a **user-facing CLI wrapper**:

- **`defaultappctl-user`** — a helper that waits for dependencies, retries as needed, and runs explicitly as the logged-in user.

---

## ⚠️ Important Limitation: Default Browser

If you are setting the **default browser** (`http` / `https`):

- **End-user GUI context is required**
- Defaults must be applied **while logged in as the user**
- This typically means:
  - The **end user** runs `defaultappctl-user`, or
  - A **helpdesk / imaging technician** runs it while logged in

> **There is no supported or reliable way to silently force the default browser ahead of a user session.**  
> No workaround was found to bypass this limitation.

If you discover a supported method around this, please share it.

---

# How‑To Use This Tool for Administrators

There are **three primary ways** to use this project.  
Which one you choose depends on:

- Your MDM (Intune, Jamf, etc.)
- Whether you need to set the **default browser**
- Whether you want **zero user interaction**


---

## 1. ✅ Recommended Method (Most Flexible)

This method supports **default browsers**, delayed installs, and real-world app timing.

### Microsoft Intune

1. Deploy the PKG via Intune  
2. Let the **postinstall** run (this installs `defaultappctl-user`)  
3. While logged in as the user, run:

        defaultappctl-user apply

This can be done by:
- The end user (with instructions)
- Helpdesk staff
- Imaging / provisioning teams

---

### Jamf Pro

1. Deploy the PKG via Jamf  
2. Choose **one** of the following:
   - Embed `postinstall.intune` into the PKG `postinstall`, **or**
   - Run `postinstall.intune` as a Jamf policy script  

   > If you encounter timing or context issues when running it as a separate script, embedding it directly in `postinstall` is recommended.

3. While logged in as the user, run:

        defaultappctl-user apply

---

## 2. Alternative: Publicly Hosted PKG + curl

Useful for testing, break-glass, or ad-hoc provisioning.

1. Host the PKG on an internal or public web server  
2. As the logged-in user:

        curl -L -o DefaultAppCtl.pkg https://example.com/DefaultAppCtl.pkg
        sudo installer -pkg DefaultAppCtl.pkg -target /
        defaultappctl-user apply
   > If you know the dependencies are installed then you can just run the package normally without the installer command. 

⚠️ This still requires user interaction for default browser changes.

---

## 3. Zero‑Interaction Method (No Default Browser)

If you **do not need to set the default browser**, this method is preferred.

### How it works

- Deploy the PKG via MDM  
- Create a **user-context script** that contains the logic from the embedded `postinstall`  
- Run it automatically in the user context  

This ensures:
- No user prompts  
- No manual execution  
- Fully automated deployment  

### Notes

- The embedded `postinstall` **does not wait for dependencies**
- For initial provisioning:
  - Add dependency checks,
  - Delay execution until apps are installed **or**
  - Have the script run repeatedly
- In Intune or Jamf, you can expose the PKG via:
  - **Company Portal** (Intune)
  - **Self Service** (Jamf)

---

# Technical Details 

The sections below are intended for administrators or developers who want to **modify, extend, or deeply understand** how DefaultAppCtl works.

---

## Identifier

- **Package identifier:** `com.yourorg.defaultappctl`

---

## Repository Layout (typical)

- `src/DefaultAppCtl.swift` — Swift CLI tool  
- `resources/defaults.json` — default mappings (strict JSON)  
- `pkg_scripts/postinstall` — base installer script  
- `pkg_scripts/postinstall.intune` — installs the user CLI wrapper  
- `build_pkg.sh` — builds the `.pkg`  
- `.work/` — build staging/output  

---

## Requirements

- **macOS 12+** at runtime  
- Xcode Command Line Tools (for `swiftc`) to build  
- `pkgbuild` (included with macOS developer tools)

---

## Build

> **Do NOT use `sudo` to build.**

        zsh ./build_pkg.sh

If `.work` is owned by root from a previous build:

        sudo rm -rf .work

Build log:

        .work/build.log

---

## Installed Payload

### Core tool

- Binary: `/usr/local/bin/defaultappctl`  
- Config: `/Library/Application Support/DefaultAppCtl/defaults.json`

### User CLI wrapper

- Binary: `/usr/local/bin/defaultappctl-user`  
- Man page: `/usr/local/share/man/man1/defaultappctl-user.1`

### Logs / state

- User runs: `/var/tmp/defaultappctl.<uid>.manual.user.log`  
- State: `/var/tmp/defaultappctl.<uid>.manual.user.state.json`

---

## CLI Usage (Core Tool)

        defaultappctl --apply --mode root|user --config <path> --state <path> --log <path>

Example:

        sudo /usr/local/bin/defaultappctl \
          --apply --mode root \
          --config "/Library/Application Support/DefaultAppCtl/defaults.json" \
          --state  "/Library/Application Support/DefaultAppCtl/state.json" \
          --log    "/var/log/defaultappctl.log"

---

## Configuration: defaults.json

Strict JSON (no comments).

Example:

        {
          "urls": {
            "mailto": "com.microsoft.Outlook",
            "http": "com.google.Chrome"
          },
          "types": {
            "com.adobe.pdf": "com.adobe.Acrobat.Pro"
          }
        }

---

## Execution Modes (Why Both Exist)

macOS maintains default handlers differently for root vs logged-in users.

- `--mode root` is best-effort  
- `--mode user` is authoritative  

The `defaultappctl-user` wrapper exists to make user-mode execution safe and repeatable.

---

## Exit Codes

- `0` — success  
- `20` — failures in root mode  
- `21` — failures in user mode  
- `10` — macOS too old  
- `11` — invalid arguments  
- `12` — config decode failure  

---

## Troubleshooting

        tail -n 200 /var/log/defaultappctl.log
        cat "/Library/Application Support/DefaultAppCtl/state.json"

Bundle ID validation:

        mdfind "kMDItemCFBundleIdentifier == 'com.google.Chrome'" | head

---

## Security / Safety Characteristics

- No network access  
- No shelling out from Swift  
- Uses bundle identifiers  
- Best-effort logging  
- Deterministic application order  

---

## Build Notes (Swift)

This project uses `@main` and must be compiled with:

        -parse-as-library

The provided `build_pkg.sh` enforces this flag.
