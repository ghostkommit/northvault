# QR matrix encoder

Unmodified `vendor/QRCode/*.js` from **qrcode-terminal 0.12.0**, obtained from the
locally installed npm distribution. Source: https://github.com/gtanner/qrcode-terminal.
These files contain Kazuhiko Arase's QRCode for JavaScript (2009), with its MIT
notice retained in `QRCode/index.js`. The containing package's Apache-2.0 LICENSE
and package metadata are also retained. `SHA256SUMS` pins the copied files.

Only the pure QR encoder is used, not the terminal UI or Node runtime. It runs in
Apple JavaScriptCore without host/network/filesystem bindings. Swift supplies
bounded UTF-8 bytes as arguments (the upstream byte writer otherwise truncates
Unicode characters). `scripts/bundle-qr-encoder.py` packages these files into a
checked-in Swift constant, without changing their contents. The wrapper adds a
one-module border expected by EFQRCode; Northvault adds its full quiet zone.

This replaces the CoreImage encoding/rasterization boundary: on the development
host the old filter produced an output extent but both hardware and software
`CIContext.createCGImage` returned nil. EFQRCode still draws the modules and embeds
the supplied logo using CoreGraphics. There is no silent unbranded fallback.
