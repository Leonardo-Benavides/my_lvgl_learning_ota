# my_lvgl_learning OTA

Public OTA payloads for `my_lvgl_learning`.

Publish only these release artifacts:

- `manifest.json`
- `firmware/my_lvgl_learning.bin`

The firmware expects `firmware.sha256` to be the `Validation hash` reported by `esptool image-info`, not the file `sha256sum`.

## Release a new OTA version

Run the release helper from this repo:

```bash
scripts/release_ota.sh
```

By default it bumps the manifest patch version, writes the same version into
`../my_lvgl_learning/sdkconfig`, builds the app, copies the new firmware,
updates `size` and the esptool `Validation hash`, commits the OTA artifacts, and
pushes the current branch.

Useful variants:

```bash
scripts/release_ota.sh --version 0.2.0
scripts/release_ota.sh --bump minor
scripts/release_ota.sh --no-push
scripts/release_ota.sh --no-git
```
