# Notices

rehalo's original code is released under the [MIT License](LICENSE). The items below are not covered
by that grant.

## Material derived from SmartHalo products

Parts of this project were produced by reverse engineering the SmartHalo 2 firmware and the official
SmartHalo Android app, so that a device can keep working after its maker closed. The firmware source
was published without an explicit licence, and no rights holder has granted a licence for this work.
These parts are provided for interoperability with your own device, and the MIT grant does not extend
to them:

- `clients/ios/SH2Protocol/Sources/SH2Protocol/Commands.swift`
- `clients/ios/SH2Protocol/Sources/SH2Protocol/FirmwareConstants.swift`
- `clients/ios/SH2Protocol/Sources/SH2Protocol/Navigation/`
- `sh2-core/` protocol constants and command layouts
- `site/firmware.js`
- `emulator/preview/halo-view.js`: the LED driver's gamma table
- `emulator/display/`: the stand-ins for the firmware interfaces it builds against (the firmware
  itself is read from your copy and not included)

SmartHalo is a trademark of its respective owner. rehalo is an independent project, not affiliated
with or endorsed by SmartHalo or CycleLabs.

## Third-party material

- **Unbounded font:** © The Unbounded Project Authors, SIL Open Font License 1.1. See
  [`site/assets/fonts/OFL.txt`](site/assets/fonts/OFL.txt). The brand SVGs contain its glyph outlines.
- **Weather data:** [Open-Meteo](https://open-meteo.com/), CC BY 4.0.
- **Maps:** Apple Maps, under Apple's terms.
