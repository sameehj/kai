# Registered-Mac development beta (Intel and Apple Silicon)

Status on 2026-10-28: a signed Universal 2 archive and copied app were built
locally. No tester ZIP, second-Mac install, or second-Mac ES enforcement test
has completed. Do not call this beta validated or invite outside testers yet.

This is a **development** build for registered Macs, not a notarized public
release. Keep SIP enabled and Apple Silicon startup security at its normal
setting. The project deployment target is macOS **13.0** for both `x86_64` and
`arm64`. Check the 2019 Intel Mac's version locally with
`sw_vers -productVersion`; the exact machine has not been inspected here.

## Register the two Macs and refresh profiles

On each test Mac, get only its **Provisioning UDID**:

```sh
system_profiler SPHardwareDataType | grep 'Provisioning UDID'
```

In Apple Developer > Certificates, Identifiers & Profiles > Devices, register
both Macs by that UDID. Create or regenerate **Mac App Development** profiles
for all three bundle IDs below, with **both test Macs** (and the development
Mac, if it remains a target) in each profile. Download/install the refreshed
profiles in Xcode or let automatic signing refresh them after registration.
The required profiles are:

| Bundle and current profile name | Required capability in its profile |
| --- | --- |
| `io.github.sameehj.kai` — `Mac Team Provisioning Profile: io.github.sameehj.kai` | System Extensions install; Network Extensions content filter |
| `io.github.sameehj.kai.storage` — `Mac Team Provisioning Profile: io.github.sameehj.kai.storage` | Endpoint Security client |
| `io.github.sameehj.kai.network` — `Mac Team Provisioning Profile: io.github.sameehj.kai.network` | Network Extensions content filter |

All three profiles in the current archive include **one** Mac. Their expiry
times are 2027-10-20 01:41:43Z (app), 01:41:39Z (storage), and 01:41:41Z
(network). The signing certificate embedded in all three expires **2027-01-25
13:20:13Z**, so it is the earlier renewal date. No signing key or Apple ID
password belongs in this repository or the tester instructions.

Apple's [registered-device guide](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
documents Mac development profiles and locating the Provisioning UDID.

## Build, sign, and package

On the signing Mac, with Xcode 15.2 or a compatible newer Xcode and XcodeGen:

```sh
KAI_TEAM=KD446VDTM2 bash scripts/build-dev-beta.sh \
  'APPLE_SILICON_PROVISIONING_UDID' 'INTEL_PROVISIONING_UDID'
```

The script builds the CLI from source as Universal 2 at macOS 13.0, generates
the Xcode project from `app/macos/storage.yml`, creates a development-signed
archive, copies the already signed app into `build/beta/<UTC time>/export/`,
checks **every Mach-O file**, all native library paths, both slices' deployment
targets, signatures, entitlements, and the three embedded profiles, then makes
`Kai-development-beta.zip` and its SHA-256 file only if both supplied UDIDs
are present in every profile. It does not install or publish anything.

The copy step is deliberate: Xcode 15.2's `-exportArchive` currently rejects
the existing profiles because they omit Kai's macOS App Groups claim, and an
Apple account connection failed during the same export attempt. The original
Xcode archive **did sign successfully**, and its copied app passed strict
nested-signature validation. Do not treat this as an Xcode Debugging export;
the clean-Mac pilot must establish whether the copied development app loads.
If refreshed portal profiles can support the App Groups claim, retry Xcode
Organizer > Archives > Distribute App > Debugging > Export and compare results.

Extension build numbers for this beta are **storage 34** and **network 19**.
They are above the locally activated 33 and 18, so the pilot can distinguish
the delivered versions from the prior installation. The app build number is 7.
The source checkout predates those locally activated versions, so live
regression testing remains essential.

For a read-only profile check after any export, run:

```sh
python3 scripts/verify-dev-beta.py /path/to/Kai.app \
  --device-udid 'APPLE_SILICON_PROVISIONING_UDID' \
  --device-udid 'INTEL_PROVISIONING_UDID'
```

The command prints profile and certificate expiry and **counts**, never UDID
values. `ProvisionedDevices` must include both requested Macs in each of the
three profiles. It fails if either is missing, a profile or certificate is
expired, a restricted capability is missing, or a native binary is not
Universal 2 with a macOS 13.0-or-earlier deployment target.

## Clean Apple Silicon pilot: same delivery path as a tester

Only after the two-UDID ZIP exists, put it in a private HTTPS file share and
download it on the pilot Mac using Safari, just as an outside tester would.
Compare `shasum -a 256 Kai-development-beta.zip` with the shipped `.sha256`
file. Extract it in Finder, move `Kai.app` to `/Applications`, and **retain
quarantine**. Do not use `xattr -d`, disable Gatekeeper, disable SIP, or lower
startup security. First-launch quarantine behavior is part of this pilot.

1. Confirm `uname -m` says `arm64`, `sw_vers -productVersion` is 13.0 or newer,
   and `csrutil status` says enabled.
2. Open `Kai.app`. Because Apple Development builds are not notarized, macOS
   may block the first launch. After attempting to open it, on macOS 13-14 use
   **System Settings > Privacy & Security > Open Anyway**. On macOS 15 and
   newer, use the same Privacy & Security security section; the latest UI may
   show **Open**, then **Open Anyway**. If no override is offered or the app is
   reported damaged, record the exact message and stop. [Apple first-launch
   guidance](https://support.apple.com/en-gb/102445).
3. In Kai, activate Storage and Network. Approve the system extensions in
   **Privacy & Security** (macOS 13-14) or **General > Login Items & Extensions**
   (macOS 15+). Give **Kai Storage's extension** Full Disk Access under Privacy
   & Security. Restart only if macOS says activation will finish after reboot;
   relaunch Kai afterward.
4. `systemextensionsctl list` must show storage **34** and network **19** as
   `[activated enabled]`. A running extension alone is insufficient: check
   `/tmp/kai-storage.log` for a *fresh* `es_new_client result=0` and
   `subscribed 10 file auth events` after activation. Check
   `/tmp/kai-storage-health.json` for current timestamp and mode. If it says
   `NOT_PERMITTED`, review Full Disk Access.
5. Make a disposable, non-secret `~/kai-beta-pilot/probe.txt`, and add its
   exact path to Kai's Protected files in the UI. In **Log/Watch** mode, ask a
   supported agent in that folder to read it. The read must succeed and Kai's
   Activity or `/tmp/kai-storage.log` must record **would-block** for that
   exact path. Switch to **Block**, retry from the supported agent, and confirm
   the read fails with a **BLOCK** record. Do not use an ordinary Terminal
   `cat` as the attribution test. Record agent name, macOS version, delivered
   extension versions, and event times. If a grant or paused session is active,
   clear it through Kai's UI before this test.

Pass the pilot only when **package built**, **installed on second Mac**, and
**ES enforcement verified** are all independently recorded. An extension
activation or a green UI indicator alone cannot satisfy the third milestone.

## Intel validation and removal

For the 2019 Intel Mac, use the **same downloaded ZIP and first-launch route**.
Confirm `uname -m` is `x86_64`, macOS is at least 13.0, SIP is enabled, all
four bundled native executables contain `x86_64`, and both extension versions
match 34/19. Repeat the fresh ES client/subscription and Log/Block disposable
file test. Do not invite that tester until the Apple Silicon pilot passes.

To remove Kai, have the human run `kai uninstall all` before deleting the app
so fail-closed agent hooks are removed. In Kai, turn Storage off (requests ES
deactivation) and Network off (disables the filter), quit Kai, remove the app,
then check `systemextensionsctl list`; restart if removal is pending. The
Makefile's `uninstall` target only removes an installed CLI. The app registers
the `io.github.sameehj.kai.control` LaunchAgent but has no matching
`SMAppService.unregister()` path yet; check Login Items and the launch agent
after removal. This is a known cleanup gap, not a complete uninstaller.

[Apple system-extension installation and removal](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers)
and [Apple's result-after-reboot guidance](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequestdelegate/request%28_%3Adidfinishwithresult%3A%29)
cover the approval and restart behavior.
