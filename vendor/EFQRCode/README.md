# EFQRCode generator subset

MIT-licensed generator from [EFPrefix/EFQRCode 6.2.2](https://github.com/EFPrefix/EFQRCode/tree/6.2.2),
tag revision `3a6c5012f1a0df404a92e55bb01b4b685ff5a2d1`.

This is a locally maintained **source subset**, not an untouched upstream release.
Source was read from GitHub's file views because archive downloads were unavailable.
The generator retains image/icon composition, correction levels, sizing and styling.
Its original support was extracted from `BinaryInteger+`, `CGColor+`, `CGImage+`, `CIColor+`, `CIImage+`,
`EFInputCorrectionLevel`, `EFIntSize`, `EFPointStyle`, `EFQRCodeMode`, `EFUIntPixel`,
and `EFWatermarkMode` in upstream `Source/`.

Local changes: comments and whitespace condensed; support combined into one file;
unused CoreImage QR pixel helpers removed after replacing the encoder;
unused conversion helpers, the pre-macOS-14 branches, non-CoreImage encoder fallback,
recognition, GIF, migration and Objective-C facade files omitted. The CoreImage pixel-extraction path is replaced by the pinned, locally bundled
Arase encoder from `../qrcode-terminal` running in JavaScriptCore. This avoids a
reproduced `CIContext.createCGImage` failure even in software mode. No network,
filesystem access, Node runtime, or build plugins are involved. EFQRCode rasterizes
the modules and embeds the image. Retain LICENSE in app bundles.

Northvault uses only UTF-8, high correction, square black modules, white background,
integer magnification and `withIcon`. The application wrapper limits input/resources,
adds a quiet zone, and verifies decoding before showing a frame. Never log payloads.
Run `bash scripts/test-qr.sh` after changing this subset or the application wrapper.
