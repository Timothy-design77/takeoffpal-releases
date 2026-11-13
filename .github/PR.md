# T-369 handoff: sign and notarize the Mac DMG

Written here because this cloud session could not reach the box (`/workspace/CloudEnv`), so no "Resume here" line was
added to the T-369 brief.

- PR: https://github.com/Timothy-design77/takeoffpal-releases/pull/7 (draft, Red: do not merge until Tim's yes on the
  exact head commit)
- Branch: `claude/t369-mac-sign-notarize-85mf59` (the session's designated branch, in place of `t369-mac-sign-notarize`)
- Code commit: `cc4cc022bb45d1edd93f7d471d2f7d34838bf1a8`. The head commit adds only this file on top of it.

## Files changed
- `.github/sign-and-notarize-mac.sh` (new)
- `.github/mac-reader-entitlements.plist` (new)
- `.github/workflows/mac-dmg.yml`
- `.github/workflows/ship.yml`
- `.github/PR.md` (this note)

## Checks run
- actionlint 1.7.12 + shellcheck 0.11.0 on all workflows: clean. shellcheck on the script: clean. The plist parses.
- Publish note check from ship.yml, 7 cases: Windows-only and Windows+mac pass; wrong mac sha, wrong mac url, mac url
  for another tag, wrong Windows sha and a missing Windows entry all fail.
- Dry run of the script on Linux against the real beta8 TakeoffPal.app, with the Apple tools stubbed:
  - Unsigned and partial secrets give the unsigned DMG.
  - Signed: 55 Mach-O files signed, entitlements on the 4 reader executables only, then app, DMG, notarize, staple
    and verify, in order.
  - Fails on notary Invalid, Gatekeeper not saying notarized, a missing identity and a wrong team.
  - No secret value in the output.
- Not run: mac-dmg and ship were not dispatched. Nothing was signed or notarized for real, and nothing ran on macOS.

## Left for after Tim provides the cert and API key
1. Add the repository secrets `APPLE_DEVELOPER_ID_P12` (base64 .p12), `APPLE_DEVELOPER_ID_P12_PASSWORD`,
   `APPLE_TEAM_ID`, `APPLE_API_KEY` (.p8 text), `APPLE_API_KEY_ID` and `APPLE_API_ISSUER`.
2. Run mac-dmg on a throwaway draft tag only, then run install-test on that tag. This proves python and Codex under the
   hardened runtime.
3. If notarization or Gatekeeper rejects the shell-script main executable, add a Mach-O launcher in Estimator's
   build_unix_beta.py.
4. Only then pass `--mac` to Estimator's `ship/update_note.py`.
