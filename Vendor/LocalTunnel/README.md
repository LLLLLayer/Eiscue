# Local tunnel provenance

Eiscue's embedded local tunnel is based on the IPv4 packet-reflection implementation in **LocalDevVPN / StosVPN**, by Stossy11, SideStore Team and jkcoxson.

Reference source: https://github.com/jkcoxson/LocalDevVPN/tree/af3fd697803ada4ac2b8d518358f5ab0a534844c

The extension code is in `Apps/EiscueTunnel/`. It fixes the address pair to the DeviceKit defaults, validates packet headers and address scope, serializes provider callbacks and stops old read loops when the tunnel ends. Eiscue does not copy the upstream application, name, icon, settings UI or analytics. It has its own App configuration manager and user controls.

The upstream custom **StosVPN License** is retained verbatim in `LICENSE`, along with `LICENSE-old`. This is not a plain MIT license. Attribution is also included in Eiscue's README and About page. These notices apply to the incorporated/refactored tunnel implementation; they do not select a distribution license for the rest of Eiscue.
