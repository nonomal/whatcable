# Decision Log

Architectural and design decisions for WhatCable, recorded as they happen so future contributors (and future-us) can understand why things are the way they are.

---

## 001: Prefer root USB device speed over HPM SuperSpeedSignaling for USB3 bullet

**Date:** 2026-05-15
**Issue:** [#140](https://github.com/darrylmorley/whatcable/issues/140)
**PR:** [whatcable-app#22](https://github.com/darrylmorley/whatcable-app/pull/22)

### Context

Two IOKit services describe the USB3 link speed from different angles:

- **HPM SuperSpeedSignaling** (`IOPortTransportStateUSB3`): the port controller's view of the SuperSpeed PHY negotiation. Values: 1 = Gen 1, 2 = Gen 2.
- **IOUSBHostDevice Device Speed**: the xHCI host controller's enumerated device speed. Values: 3 = 5 Gbps, 4 = 10 Gbps, 5 = 20 Gbps.

On some Apple Silicon Macs, these two sources disagree. A Samsung T7 SS+ (10 Gbps device) showed Gen 1 via HPM but 10 Gbps via the host controller. macOS System Information uses the host controller value, confirming it as the more authoritative source.

### Decision

Use the root USB device's Device Speed as the primary source for the USB3 speed bullet. Fall back to HPM SuperSpeedSignaling when no device is matched to the port.

"Root device" means the device directly attached to the host controller port, not behind a hub. Identified via the locationID nibble-packed hub path (top byte = bus, remaining 6 nibbles = hub hops, left-to-right). A root device has exactly one non-zero nibble in bits 23-0.

### Why not just max() across all matched devices?

With a hub, the topology is: Mac port -[upstream link]- Hub -[downstream link]- Device. These links negotiate independently. A Gen 1 hub (5 Gbps upstream) can have a Gen 2 device (10 Gbps) on a downstream port. Taking max() would report the downstream link speed, which overstates the port's actual upstream bandwidth.

### Why not keep HPM as primary and only override when it disagrees?

Considered keeping HPM as the default and only overriding with device speed when HPM reports Gen 1 and the root device reports SuperSpeedPlus. This would be narrower and lower-risk, but it's also "magic" -- the next reader has to understand the asymmetry. The cleaner rule is: always prefer the root device speed, because it comes from the actual enumeration handshake.

### Risks and caveats

- **locationID encoding is undocumented.** It has been stable since Snow Leopard, but it's an Apple convention not guaranteed by any public API. If it changes, `isRootDevice` would misidentify devices. The code includes a comment noting this assumption.
- **No root device matched.** If `matchingDevices` returns only downstream devices (or nothing), the code falls back to HPM. This matches the pre-change behaviour.
- **os_log warning on mismatch.** When HPM and device speed disagree, a warning is emitted for diagnostics. This lets us detect new disagreement patterns without breaking anything.
