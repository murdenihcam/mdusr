# mdusr: Machinedrum USR machine loader for norns

Two pages (E1 switches):

1. **LOAD**: browses USR machines from the sites below, grouped by source and category, with short descriptions. Pick one and it sends the .syx to the Machinedrum, paced, with a progress bar.
2. **BACKUP**: requests or captures Machinedrum SysEx dumps, saves them as .syx, and restores them.

## Install

Copy the `mdusr` folder to `dust/code/mdusr` on the norns (SMB/SFTP, or maiden). Select it from SELECT. The norns needs internet for **Refresh**; everything already fetched stays cached for offline use.

PARAMETERS > EDIT: pick the MIDI device the MD is connected to (in and out).

## Controls

| | LOAD | BACKUP |
|---|---|---|
| E1 | page | page |
| E2 | scroll list / description | scroll menu |
| E3 | machine list: right = add to collection, left = remove; detail: choose file variant; collection: move file up/down | change kit / pattern / song / global number |
| K2 | back, cancel, abort send | back, abort |
| K3 | open, prepare, confirm send | run selected item |

LOAD flow: source → category (skipped when a source has only one) → machine → detail (description, version, track/RAM notes, file variants) → K3 downloads the .syx if not cached and shows a confirm screen with message count, size and estimated time → K3 sends.

## Collection (batch send)

In any machine list, turn E3 right to check a machine off (marked `*`), left to uncheck. The file added is the variant last chosen with E3 in that machine's detail view (default: the first). Machines from different sources can be mixed. The collection is saved between sessions.

**> Collection** (top of the source list) shows the files in send order:
- **> Send all**: downloads anything not cached, validates every file, shows one confirm screen (files, messages, bytes, estimated time), then sends them in order with one progress bar.
- **> Clear all**: press K3 twice.
- On a file: E3 moves it up/down, K3 removes it.

Between files, `between files` decides what happens: `auto gap` waits `gap between files ms` (default 1500) and carries on; `wait for K3` stops before each file so the next MACHINE MGR slot can be armed. K2 stops a batch; the result screen says how many files completed.

Before confirming, set the MD to receive: **GLOBAL > FILE > MACHINE MGR, pick a slot, arm RECV** (per the MDX X.20 readme). If the MD shows BUFFER FULL, lower `max bytes/sec` or raise `gap between msgs`.

## Sources

| Source | How it is read |
|---|---|
| wftlrd.uk/machinedrum-usr | `manifest.json` (the page itself is JavaScript-only). Categories = banks, ordered by bank load order. |
| murdenihcam.github.io/murdenihcam-usr-machines | `machines.js` (JSON array). Prefers a `machines.json` if one is ever published. Each variant (all banks / ROM / E12) is a selectable file. |
| moncalamari.github.io/dbx-usr-machines | page HTML for names + descriptions; .syx from each repo's latest GitHub release. |
| github.com/bento909/MDX20-User-Machines | GitHub tree API; every folder with a .syx is a machine, description from the folder README. |
| MDX X.20 bundle (github.com/jmamma/MDX) | newest `firmware/mdx/X.20/*.zip` is downloaded once and unpacked on the norns (python3 or unzip). Files over 100 KB (the OS image) are never listed. Descriptions come from the readme inside the zip. |
| Local files | any .syx placed in `dust/data/mdusr/local/`. |

Add more sites in `lib/sources.lua`. GitHub's unauthenticated API allows 60 requests per hour; one full refresh uses about 5.

## Settings (PARAMETERS)

- `chunk bytes` (128): bytes per MIDI write.
- `max bytes/sec` (2500): pacing; DIN MIDI tops out at 3125.
- `gap between msgs ms` (150): pause between SysEx messages.
- `request timeout s` (2): backup page wait per request.
- `between files` (auto gap / wait for K3) and `gap between files ms` (1500): batch sends.
- `refresh on start`: if empty / always / never.

## BACKUP page

- **Listen**: capture every SysEx that arrives (for dumps sent from the MD front panel).
- **Request kit / pattern / song / global**: sends the MD SysEx request (IDs 0x53 / 0x68 / 0x6A / 0x51) and waits for the reply.
- **Full backup**: requests globals 1-8, kits 1-64, patterns A01-H16, songs 1-32 (232 requests, a few minutes) and saves `full_<date>.syx`.
- **Save capture** / **Clear capture**.
- **Restore a file**: lists `dust/data/mdusr/backups/` newest first; sends the chosen file with the same pacing. Dumps go back to the slots stored inside them.

Incoming SysEx is reassembled across MIDI callbacks; realtime bytes (clock) inside a dump are ignored and a message broken by another status byte is dropped.

## Files

- `dust/data/mdusr/cache/`: index per source (JSON) and downloaded .syx/zip.
- `dust/data/mdusr/backups/`: saved dumps.
- `dust/data/mdusr/local/`: your own .syx files.
- `dust/data/mdusr/collection.json`: the collection.

## Tests

`lua5.3 test/run_tests.lua` runs the script against mocked norns APIs and fixture copies of each site's data format (no hardware, no network).
