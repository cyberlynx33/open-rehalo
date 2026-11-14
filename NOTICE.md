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
- **Maps:** Apple Maps, under Apple's terms (the default map engine, the 3D route view and search).
- **MapLibre Native iOS** ([maplibre/maplibre-native](https://github.com/maplibre/maplibre-native)),
  BSD 2-Clause, © MapLibre contributors; the optional map engine, added as a Swift package.
- **Map data:** © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors, Open Database
  License (ODbL). Vector tiles and styles by [OpenFreeMap](https://openfreemap.org/) (MIT), from
  [OpenMapTiles](https://openmaptiles.org/) (© OpenMapTiles).
- **Topographic map and orthophoto of Spain:** Instituto Geográfico Nacional ([ign.es](https://www.ign.es/)),
  WMTS services `mapa-raster` (MTN) and `pnoa-ma` (PNOA), CC BY 4.0 (`ign.es`, `scne.es`).
- **Terrain tiles:** [Mapterhorn](https://mapterhorn.com/), code BSD 3-Clause; the elevation data from the
  IGN's digital terrain models (CC BY 4.0 scne.es) in Spain and Copernicus GLO-30 elsewhere.
- **Cycle network overlay:** [CyclOSM](https://www.cyclosm.org/), tiles CC BY-SA 2.0, rendered by
  OpenStreetMap France under the OSMF tile usage policy (online only).
- **Routing:** [BRouter](https://github.com/abrensch/brouter), MIT, run on a server of the rider's;
  nothing of it is shipped with the app.
