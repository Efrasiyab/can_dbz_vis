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

See [docs/architecture.md](docs/architecture.md) for the running system overview.

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

Monitor keys: `c` opens channel mapping, arrows navigate, `p` pins the selected
message or signal, `/` filters, `g` limits rows to database messages, `t` toggles
aggregate/trace, `5` opens Pins, `space` pauses the display, and `?` shows help. Use `+` and `-`
to adjust the frame rate; the setting is saved in the user config directory.

On Transmit, use the arrows to choose messages and signals, `+`/`-` to edit
values, `c` to cycle signal choices, `k` to toggle automatic counter increments,
`m` for periodic mode, `[`/`]` to set the period, `s` to send/start/update, and
`x` to stop a periodic job. See [docs/usage.md](docs/usage.md) for Sent status
semantics.

On Plot, arrows choose a database signal, `p` adds it, `x` removes the selected
series, `+`/`-` adjust the time window, PageUp/PageDown scroll through history,
and `space` freezes/resumes the displayed window while sampling continues. FPS
and plot window are saved in user settings.

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
