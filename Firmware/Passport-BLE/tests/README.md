# Host firmware fixtures

`bash Scripts/test-board-companion.sh` compiles the production companion state
machine and row decoder with UBSan. Its five scenario groups cover malformed
12-byte packets, stop generation and all input-opcode rejection, heartbeat/local
status precedence, debounced stop and deliberate unlock, and every row of all
47 expression/text/digit bitmaps (including output guards and malformed input).
This does not validate ADC thresholds, the ST7789, DMA callbacks, NimBLE event
ordering or physical input; those require separate board/phone acceptance.

## Authentication

This fixture compiles the production `board_auth.c` against in-memory ESP-IDF
platform stubs. OpenSSL computes real HMAC-SHA256. It never opens a serial port,
connects to a phone, or writes hardware. Synthetic keys and nonces are test data.

From the repository root, with OpenSSL development headers/libraries installed:

```sh
bash Scripts/test-board-auth.sh
```

The script uses Homebrew's Apple Silicon OpenSSL 3 prefix when available,
otherwise the compiler's system paths. Set `BOARD_AUTH_OPENSSL_PREFIX` for a
different installation. `CC` and `BOARD_SANITIZERS` are also configurable.
The six scenario
groups cover independently generated fixed HMAC vectors, stale commands and
proofs, tampering without counter advancement, asynchronous reply sequences,
persistent identity/key reuse, no key replacement, the enrollment deadline,
malformed packets, corrupt records, and storage/crypto failures. The fixture
does not establish BLE, USB HID, hardware NVS, or real-device acceptance.
