# Architecture

`can_dbz_vis` is a Zig terminal application built around an Elm-style model/update/view loop. The UI owns configuration and presentation; workers exchange fixed-size records through bounded queues and publish snapshots through triple buffers.

## Data Paths

- **Live RX:** one receiver per adapter writes `Frame` values to SPSC queues. The ingest thread owns RX/TX message tables, computes statistics, samples plotted signals, publishes Monitor/Sent snapshots, and forwards records to the logger.
- **TX:** the UI encodes database messages and sends jobs to the TX scheduler. The scheduler calls adapter writes and sends accepted/failure events back to ingest. TX is not started in replay or demo mode.
- **Plot:** ingest sends selected signal samples to the plot worker. The worker keeps fixed-capacity histories and publishes min/max-decimated snapshots.
- **Logging:** ingest is the sole log producer. A bounded record queue feeds a file-writer thread that writes versioned JSONL records.
- **Replay:** the replay source streams records into the same ingest queues. A separate indexer builds seek offsets, marker metadata, and ten-second state keyframes. Backward seek restores ingest and plot state before fast-forwarding from a keyframe.
- **Demo:** a cancellable source generates database-shaped frames into the engine input queue, reusing normal ingest, plotting, and logging paths.

## Modes

- **Live:** adapters, ingest, TX scheduler, and optional logging.
- **Replay:** no adapters or TX scheduler; includes indexed seek and marker navigation.
- **Demo:** virtual synthetic input; Connect and Transmit are disabled.

## Adapter Recovery

Virtual adapters are available everywhere. SocketCAN is Linux-only. PEAK PCAN-Basic is included on Linux GNU and Windows when `-Dpeak=true`; its library is loaded only during PEAK enumeration or connection. Bus-off and disconnect status are shown per bus. Recovery is currently operator-driven: recover the interface/controller, then reconnect with `c`.

See [design.md](design.md) for detailed subsystem contracts and [adapters.md](adapters.md) for the adapter API and supported backends.
