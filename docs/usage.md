# Usage

## Transmit

Select a database message with left/right and a signal with up/down. Adjust the
selected physical value with `+` and `-`. The payload preview is encoded with
the loaded database and validated against signal bounds and multiplexing rules.
Use `c` to cycle a signal's declared choices. Signals named `Counter` or `Cnt`
can use the automatic increment toggle, controlled by `k`.

- `Enter` or `s`: send once.
- `m`: toggle one-shot/periodic mode.
- `c`: cycle the selected signal's choices when it has choices.
- `k`: toggle automatic counter increments for counter signals.
- `[` / `]`: decrease/increase the period by 10 ms.
- `s`: start a periodic job or update its payload while it is active.
- `x`: stop the active periodic job.

## Sent Status

The Sent tab is labeled **Sent (driver-accepted)**. `ok` means the kernel or
adapter accepted the frame into its transmit queue. It does not confirm that the
frame won arbitration or was acknowledged on the bus.

- `queue_full`: bounded retry did not get the frame into the queue.
- `bus_off`: the adapter reported bus-off; the frame was not sent.
- `driver_error`: disconnected channel or another adapter failure.

The timestamp is the monotonic software time when the write call returned.
Frames observed on the bus appear separately in Monitor; receive-own-messages
echo is controlled by the channel backend. Periodic jobs use monotonic deadlines
and skip missed sends rather than sending a catch-up burst.

## Plot

On the Plot tab, left/right select a message and up/down select a signal. Press
`p` to add or `x` to remove a series. `+` and `-` widen or narrow the displayed
time window; the selected window is saved in `settings.json`. `space` freezes the
visible chart while the plot worker continues sampling. PageUp/PageDown scroll
the displayed time range without pausing collection. Each series is decimated
by per-column minima and maxima so brief peaks remain visible at 30 fps.

## Pins

Press `5` to open the dedicated Pins view. Use up/down to select a pin and `p`
to remove it. Pins are shared across Monitor, Plot, and session restarts.

## Replay

Run `can_dbz_vis --replay FILE.canlog.jsonl [FILE.dbc | FILE.can.json]` to play a
recording through the same Monitor, Sent, and Plot ingest path. If the database
is omitted, a bus-only database is synthesized and frames display raw. Replay
does not open adapters or enable Transmit. Add `--speed X` to set the initial
speed from 0.1x to 10x, for example `--speed 2.0`.

- `space`: play/pause.
- `+` / `-`: increase/decrease playback speed from 1x, bounded to 0.1x–10x.
- Right arrow or `.`: advance one frame while paused.
- `,`: step backward one frame.
- Left arrow or `[`: seek backward one second; `]` seeks forward one second.
- `n` / `N`: jump to the next / previous marker.
- Click the timeline to seek to that point in the recording.

Replay builds duration, sparse seek-point, marker, malformed-line, and ten-second
keyframe metadata on a background indexer while playback starts. The timeline marks the current replay position and
recorded markers. Backward seek restores the nearest keyframe, clears Plot history,
and replays only the records from that point to the target. Backward stepping
rebuilds from the nearest keyframe and advances to the previous frame, including
when crossing a keyframe boundary.

## Demo

Run `can_dbz_vis --demo FILE.dbc` or `can_dbz_vis --demo FILE.can.json` to
generate synthetic traffic using the database's message IDs, buses, lengths,
and classic/FD types. The included sample can be launched with
`zig build run -- --demo examples/demo.can.json`. Demo mode uses the
same ingest, Monitor, Plot, and logging paths as live input; Transmit and Connect
are disabled. Add `--log PATH` to record the generated frames.
