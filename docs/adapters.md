# Adapter Contract

Adapters translate between the fixed-size `can.Frame` model and a physical or
virtual CAN channel. `can.adapter.Adapter` is the runtime interface; a backend
provides channel enumeration, an `open` function, and capability flags.

## Runtime Rules

- `read` writes at most `out.len` frames and returns the number written. It must
  return within `timeout_ns`; returning zero immediately is valid.
- `write` is non-blocking or bounded-blocking. A full transmit queue is reported
  as `error.QueueFull`; listen-only channels reject writes.
- RX and TX may call an adapter concurrently. Backend-owned mutable state must
  be synchronized or split by direction. `close` is called after those workers
  stop.
- Backend enumeration returns `ChannelInfo` values whose channel names fit the
  fixed name capacity. `ChannelConfig` carries bitrate requests, listen-only,
  and receive-own-messages settings.
- `Status` describes the most recent known channel state. Errors from an
  individual read or write are returned directly and must not block other
  channels.

## Backends

The virtual backend is the reference implementation and is available on every
target. Its `virtual0` bus fans frames out to open endpoints, supports CAN FD,
and is used by the adapter tests.

SocketCAN is registered on Linux only. It uses raw Linux syscalls, enables CAN
FD and error-frame reception, batches receive calls with `recvmmsg`, and maps
kernel realtime timestamps into the process monotonic domain. One raw socket is
used per adapter so Linux's own-message option applies to frames sent by that
adapter while reads and writes remain concurrent.

PEAK PCAN-Basic is registered on Linux GNU and Windows builds when `-Dpeak=true`
(the default for those targets). `libpcanbasic.so` or `PCANBasic.dll` is opened
only when PEAK channels are enumerated or connected. Current enumeration covers
PCAN USB and PCI handles 1–8. Classic bitrate requests support 1M, 800k, 500k,
250k, 125k, 100k, 50k, 20k, 10k, and 5k bit/s; FD timing is generated for
bitrates that divide the 80 MHz PCAN clock. Use `-Dpeak=false` for builds that
must not include the backend. A missing PCAN-Basic library is reported in the
Connect dialog while other backends remain usable.

Bus-off and disconnect conditions are shown per bus. Recovery is currently
operator-driven: recover the interface/controller, then open Connect with `c` and
map the channel again.

## Adding a Backend

Implement `adapter.Backend` and `adapter.Adapter.VTable`, then add the backend to
`can/registry.zig` behind its target guard. Add conformance tests for channel
enumeration, classic-frame round-trip, CAN FD when supported, listen-only
behavior, receive-own-messages, bounded reads, and clean close. The virtual
backend tests always run; SocketCAN loopback tests run when `vcan0` is present.
