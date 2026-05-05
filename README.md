# my_lvgl_learning OTA

Public OTA payloads for `my_lvgl_learning`.

Publish only these release artifacts:

- `manifest.json`
- `firmware/my_lvgl_learning.bin`

The firmware expects `firmware.sha256` to be the `Validation hash` reported by `esptool image-info`, not the file `sha256sum`.
