# can_dbz_vis

A Zig terminal UI (TUI) for monitoring, decoding, transmitting, plotting, logging
and replaying CAN / CAN FD traffic.

> **Warning:** This project is under active development and is not ready for any type of use.
> Phase 9 hardening is in progress. Live Monitor, Transmit, Sent, Plot, JSONL recording,
> indexed replay, PEAK PCAN-Basic, and database-driven demo traffic are available.

- Database parsing and signal decoding/encoding are powered by [`can_dbz`](https://github.com/Efrasiyab/can_dbz).
- Terminal rendering and input are powered by [`zigzag`](https://github.com/Efrasiyab/zigzag).
- Databases are loaded from **CAN JSON v1** (`.can.json`) or **DBC** (`.dbc`).
- Available adapters: virtual on all platforms, SocketCAN on Linux, and PEAK
  PCAN-Basic on Linux GNU and Windows when enabled with `-Dpeak=true`.

See [docs/architecture.md](docs/architecture.md) for the running system overview and
[docs/design.md](docs/design.md) for subsystem contracts and the phased implementation plan.

## Quick start

This project requires Zig **0.17.0**. Dependencies are pinned in `build.zig.zon` and fetched by Zig during the build.

Build and run:

```sh
zig build
zig build run -- FILE.dbc
zig build run -- FILE.can.json
zig build run -- --list-channels
zig build run -- --log capture.canlog.jsonl FILE.dbc
zig build run -- --replay capture.canlog.jsonl
zig build run -- --replay capture.canlog.jsonl FILE.dbc
zig build run -- --replay capture.canlog.jsonl --speed 2.0
zig build run -- --demo examples/demo.can.json
```

## Use a Real CAN Adapter

1. Connect the adapter to the CAN bus and install its OS driver. Confirm the
   adapter supports the bus bitrate and CAN mode (Classic CAN or CAN FD).

1. On Linux, configure the SocketCAN interface with the bitrate used by the
   network. For example, replace `can0` and `500000` with the actual interface
   and bitrate:

   ```sh
   sudo ip link set can0 down
   sudo ip link set can0 type can bitrate 500000
   sudo ip link set can0 up
   ```

   Do not change the bitrate on a live network unless it is known to be correct.
   SocketCAN is available on Linux. PEAK PCAN-Basic is available on GNU/Linux
   and Windows builds; install the vendor driver and make `libpcanbasic.so`
   (Linux) or `PCANBasic.dll` (Windows) available to the application. PEAK is
   enabled by default for these targets and can be disabled with `-Dpeak=false`.

1. List the channels detected by the build:

   ```sh
   zig build run -- --list-channels
   ```

1. Start the monitor with the database, then press `c` to open Connect. Use
   up/down to select the hardware channel, left/right to select the database
   bus, `m` to map them, and Enter to connect. Press Esc to cancel. A channel
   must be mapped to a database bus before its traffic appears in Monitor.

   Connect proposes rates from CAN JSON bus fields or a valid DBC `BS_` bitrate.
   If none is present, it proposes 500 kbit/s nominal and 2 Mbit/s data. Use
   `n` to cycle nominal rates, `f` to switch Classic CAN/CAN FD, and `d` to
   cycle the CAN FD data rate. FD is proposed when the database has FD timing or
   FD messages, and can only be enabled for channels reported as FD-capable.
   PEAK applies the selected rates when it opens the channel. SocketCAN rates
   remain OS-managed; configure them on the interface as shown above.

   For a database with two buses, map each bus to its own channel before
   pressing Enter. For example, select channel 1 and bus 1 and press `m`, then
   select channel 2 and bus 2 and press `m`, then press Enter. Each channel can
   map to only one bus; a two-port adapter must appear as two channels to use
   both buses at once. Buses left unmapped remain disconnected.

   ```sh
   zig build run -- FILE.dbc
   # or
   zig build run -- FILE.can.json
   ```

   You can also build a target binary first and run it directly. See
   [Build for Linux and Windows](#build-for-linux-and-windows) for target
   examples.

   On Windows, build and run the `.exe` from PowerShell:

   ```powershell
   zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -p zig-out/windows-x86_64
   .\zig-out\windows-x86_64\bin\can_dbz_vis.exe --list-channels
   .\zig-out\windows-x86_64\bin\can_dbz_vis.exe .\FILE.dbc
   ```

**Transmit sends on the connected bus.** Verify the selected channel, bitrate,
and message before sending; on Transmit, `s` sends the selected frame. A Sent
`ok` status means the driver/kernel accepted it, not that the frame was
acknowledged on the bus. See [docs/usage.md](docs/usage.md#sent-status).

Monitor keys: `c` opens channel mapping, arrows navigate, `b` folds or unfolds the
selected CAN bus, `p` pins the selected message or signal, `/` filters, `g` limits
rows to database messages, `t` toggles aggregate/trace, `5` opens Pins, `space`
pauses the display, and `?` shows help. Use `+` and `-`
to adjust the frame rate; the setting is saved in the user config directory.

On Transmit, use the arrows to choose messages and signals, `+`/`-` to edit
values, `c` to cycle signal choices, `k` to toggle automatic counter increments,
`m` for periodic mode, `[`/`]` to set the period, `s` to send/start/update, and
`x` to stop a periodic job. See [docs/usage.md](docs/usage.md) for Sent status
semantics.

On Plot, press `p` to open the scrollable bus/message/signal tree. Use arrows to
navigate and fold groups, then `Tab` on a signal to choose an existing plot or
create a new one with Left/Right and confirm with Enter. `Tab` on a plotted
signal removes it; Enter or Esc returns to the chart. `[`/`]` select a plot and
`w` edits its window in milliseconds (`0.1` ms = 100 µs, `1000` ms = 1 s).
Press `l` to set the grid's column count; enter `0` to return to Auto. For example,
set three columns to arrange nine plots as a 3×3 grid.
`s` starts or stops sampling, `x` removes the selected series, and PageUp/PageDown
scroll through history. Press `i`, then click a chart to inspect the nearest
sample time and signal values; value-table labels are shown when available.
Plot assignments and per-plot windows are saved per database and restored
stopped; FPS is saved in user settings.

On Pins, `p` opens the same signal tree, `Tab` pins or unpins the highlighted signal,
and Enter or Esc returns to the pinned list. Use `x` to remove the selected item from
that list. Pinned signal values are highlighted in yellow in Monitor.

Replay mode opens no adapters and disables TX. Use `space` to play/pause, `+`/`-`
to change speed, left/`[`/`]` to seek by one second, `n`/`N` to jump between
markers, `,` to step backward, and right arrow or `.` to step forward. If a database is omitted, frames
are shown raw. Backward seeking restores the nearest ten-second keyframe.

Execute the test suite with:

```sh
zig build test
```

Run the headless virtual-CAN engine benchmark (defaults to four channels at
10,000 frames/s each for three seconds):

```sh
zig build bench
zig build bench -- --rate=5000 --seconds=5 --channels=2
```

The benchmark runs optimized and reports received throughput, drops, and
steady-state allocations. It exits with an error if drops or runtime allocations
are observed.

## Development container

`Containerfile` and `.devcontainer/` provide a Debian image with Zig 0.17.0,
`can-utils` and `iproute2`. In VS Code, run **Dev Containers: Reopen in Container**.

The container uses the host network and `NET_ADMIN`, so host SocketCAN interfaces are
visible and virtual CAN devices can be created. The `postStartCommand` creates and
brings up `vcan0` automatically when it is missing. The `vcan` kernel module belongs
to the Docker host kernel and must be loaded there once:

```sh
sudo modprobe vcan
```

Reopen the Dev Container after loading the module. Because it uses host networking,
`vcan0` is created in the Docker host's network namespace and is visible to the host
and other processes sharing that namespace. Use the interface from inside the container:

```sh
cangen vcan0 -g 10 &   # generate traffic
candump vcan0          # inspect traffic
```

## Build for Linux and Windows

These commands produce optimized x86-64 binaries in separate output directories:

```sh
# Linux x86-64, default: SocketCAN + PEAK (links glibc dynamically for dlopen)
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast -p zig-out/linux-x86_64

# Linux x86-64, fully static: SocketCAN only
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast -p zig-out/linux-x86_64-static

# Windows x86-64: PEAK
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast -p zig-out/windows-x86_64
```

| Build                        | Backends                 | Runtime dynamic dependencies                                    |
| ---------------------------- | ------------------------ | --------------------------------------------------------------- |
| `x86_64-linux-gnu` (default) | virtual, SocketCAN, PEAK | glibc; `libpcanbasic.so` loads for PEAK enumeration/connect     |
| `x86_64-linux-musl`          | virtual, SocketCAN       | none (static executable)                                        |
| `x86_64-windows-gnu`         | virtual, PEAK            | system DLLs; `PCANBasic.dll` loads for PEAK enumeration/connect |

The PEAK backend is controlled with `-Dpeak=<bool>`. It defaults to `true` on
`*-linux-gnu` and Windows, and must be `false` on `*-linux-musl`.

## Build checks

`zig build` runs the default `check` gate, compiling the application and test suite.
Use `zig build check` to invoke that gate directly, or `zig build test` to execute the
tests. The default check compiles for the selected target, so it also works for
cross-compilation.

## License

[Mozilla Public License 2.0](LICENSE)
