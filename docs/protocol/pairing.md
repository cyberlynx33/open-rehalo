# SmartHalo 2 — Pairing, password and recovery

> The device's password authentication and how to re-pair your **own** SmartHalo 2 with a new client.
> Source: `shapp/src/auth.c`, `device.c`, `record.*` (nRF side) and the official app.

## Model

- The device stores a **password of ≤32 bytes** in flash (FDS record `KEY_PASSWORD`).
- `authenticate` (`0,3`) compares the received payload byte by byte with the stored password (exact
  length). On a match: permission `0x01` + the UP channel is enabled.
- If **no password** is stored (`auth_password_len == 0`), `authenticate` with an **empty** payload
  succeeds. This is the "unpaired" state.
- `setPassword` (`0,4`) sets (`len 32`, optionally `32+crc16`) or clears (`len 0`) the password. It
  **requires an authenticated session** (permission mask active). Clearing it un-pairs the device and
  resets its name to `"smarthalo"`.

## Normal first pairing (what the app did)

1. ECDH→AES handshake (see `ble-link.md` §5).
2. `authenticate` with an empty password (unpaired device) → OK.
3. The app generates a **random 32-character password**, saves it in its local storage and sends it
   with `setPassword`.
4. From then on, it reconnects and calls `authenticate` with that saved password.

> What this means for an open-source alternative: **the client generates and keeps** its own 32-byte
> password per device, as the app did. If the device is already paired with the official app (a
> password the client doesn't have), it must be **recovered** first.

## Recovering a device that is already paired (unknown password)

The firmware includes an **unauthenticated reset** path in service 0 (registered with permission 0,
so it's always accessible):

1. `getSeed` (`0,6`) → the device returns its current 4-byte **seed**.
2. Compute the challenge = **`SHA-256( seed(4) || salt(16) )`** (32 bytes).
   - The 16-byte `salt` is a firmware constant (in `auth.c`, definition of `auth_salt`, around line
     198). The iOS app includes it in `FirmwareConstants.swift`; the JS tools read it from the firmware
     source.
3. `resetPassword` (`0,7`) + `challenge(32)`. If it matches, the device **clears the password** and
   is left unpaired. After this, an empty `authenticate` works → `setPassword` with the new password.

### Important caveats

- This path lowers the anti-theft protection: anyone within BLE range who has the salt (public) and
  the seed (which the device hands out) can un-pair the device. The firmware's own README points
  this out and suggests adding a delay (1 hour to 1 week) before allowing it. Use it only to recover
  your own device.
- The seed is randomized on every connection and `getSeed`, so read it **live** right before computing
  the challenge. An old seed won't work.

## When a ring stops taking a password it took before

The nRF checks `authenticate` against `auth_password` in RAM, which `auth_init` loads from flash
only at boot. The flash copy can drift from the RAM copy:

- `resetPassword` deletes the flash record but leaves RAM alone, so the old password keeps working
  until the next boot, and after it the ring has **no password**.
- `setPassword` updates RAM at once and queues the flash write (`rec_write`), then replies OK. The
  write is dropped silently when the record queue (4 entries) is full or flash stays full after two
  garbage collections, so after the next boot the ring is back on its **previous password**.

The nRF reboots more often than the ring seems to: the STM32 cuts its power for 1 s on every STM32
boot (`init_BLEDriver`) and on every standby change (`toggleStandby_BLEDriver`: alarm standby, the
sleep tap code). A flat battery that's charged again also boots it.

A mismatch has no cost: `auth_authenticate` just answers `RET_FAIL`, with no lockout and no
kick-out, so several passwords can be tried on one link after a single ECDH. Only the 60 s
`KICKOUT_DELAY` from the connection applies.

The link state lives as long as the BLE connection: `bslink_cryptData`, the permission mask and the
seed are only reset on `BLE_GAP_EVT_CONNECTED`. iOS can hand a relaunched app the physical link a
killed one left up, and then the ring answers the new app's plaintext `getPeriphPubKey` encrypted
with the old handshake's keys. Its key pair is fixed (`keys_init` derives it from the chip's FICR),
and the seed only changes on a new connection or `getSeed`, so with the old keys the reply decodes and
a plain `setCentralPubKey` re-keys the link.

What the iOS app does with this (`DeviceController.authenticate`):

1. It tries, over one link: its saved password, the one that password replaced, the passwords stored
   for other peripheral identifiers (another iPhone's, through iCloud Keychain), and the empty
   password.
2. If the empty password gets in, the ring is un-paired: the app gives it the saved password back
   with `setPassword`, with no reset and no reboot. The password doesn't change.
3. It asks for a recovery only when the ring answers `RET_FAIL` to all of them. A timeout, a dropped
   link or a reply that doesn't decode says nothing about the password: the app drops the link (the
   ring forgets a half-done handshake only on disconnect) and reconnects.
4. A recovery also reuses the saved password, and stores it before the ring gets it.
5. It keeps the last handshake's keys in the Keychain (this iPhone only) and starts each handshake
   with them, so a link left up by a killed launch is re-keyed instead of failing.

## Alternative route: DFU

If the reset challenge weren't available in a given device's build, the firmware README mentions
recovering through **DFU** (adding a reset command). That carries a risk of bricking the device, and
the **bootloader signing keys were not released**, so custom firmware can't be signed. Recovery
therefore doesn't depend on DFU; it uses the reset challenge over BLE.
