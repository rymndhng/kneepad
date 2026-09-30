# AGENTS.md

## Running kneepad

The app is the product: `scripts/build-app.sh` builds `build/Kneepad.app`, and the pad works while it runs in the foreground. Direct users, docs and new features to the app.

`touchd` and its LaunchAgent scripts (`scripts/install-agent.sh`, `scripts/uninstall-agent.sh`) are legacy. Leave them working, but keep them out of docs and put new behavior in the app or the shared `TouchDriver` library instead.

## Naming

The public name is kneepad (`Kneepad.app`, bundle ID `dev.rymndhng.kneepad.app`). Settings live in `Application Support/kneepad/`. Older names stay on purpose where changing them would lose user state: the log subsystem `dev.rymndhng.teach-touch`, the LaunchAgent label, and the signing identity names.
