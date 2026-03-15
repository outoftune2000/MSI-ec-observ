# EC Observe (standalone)

This repo provides a observability tool that is used to view the EC register values for MSI laptops ( GF65 thin 10UE ) .

## Files

- `ec_observe.sh`: capture snapshots, diff changes, live-watch addresses, and log manual writes.

## Quick start
Most machines require root permissions for `/sys/kernel/debug/ec/ec0/io`, so run with `sudo`:

```bash
sudo ./ec_observe.sh help
```

## One-action snapshot + diff (Auto -> Advanced style workflow)

```bash
sudo ./ec_observe.sh action auto_to_advanced
# perform one UI action
# press Enter
```

This creates before/after dumps under `./ec_logs/` and prints:

1. Unified text diff
2. Byte-level changed offsets

## Manual snapshots and diff

```bash
sudo ./ec_observe.sh snapshot before
# do one action
sudo ./ec_observe.sh snapshot after
sudo ./ec_observe.sh diff ec_logs/<before>.txt ec_logs/<after>.txt
```

## Live watch known addresses

Defaults include OFC-relevant addresses: temp, rpm, profile, cooler boost, and fan-curve bytes.

```bash
sudo ./ec_observe.sh watch 0.5
```

Custom address list:

```bash
sudo ./ec_observe.sh watch 0.5 "104,128,200,202,212"
```

## Live watch unknown (unmapped) changes

Watch a byte range and print only changes on addresses not in the known/mapped list.

```bash
sudo ./ec_observe.sh watch-unknown 0.5 0 256
```

Example output:

```text
2026-03-15T20:24:31+05:30 unknown_changes=1 [46]=75->73
2026-03-15T20:24:32+05:30 unknown_changes=1 [46]=73->75
```

## Observed findings (current hypotheses)

- Webcam toggle candidate register: byte `46` (`0x2e`)
- Seen state values: `75` (`0x4b`) and `73` (`0x49`)

Try manual write tests:

```bash
sudo ./ec_observe.sh write 46 73 webcam_toggle
sudo ./ec_observe.sh write 46 75 webcam_toggle
```

Notes:

- If the byte snaps back immediately, it may be a status/mirror byte, not the true control byte.
- Confirm with one-action diff (`action`) while toggling webcam from the OEM UI.

## Write + log (standalone instrumentation)

Every write logs to `ec_logs/ec_writes.csv` with:

- timestamp
- byte (dec/hex)
- value (dec/hex)
- profile label

Example:

```bash
sudo ./ec_observe.sh write 0xd4 141 Advanced
```

## Environment overrides

You can override addresses without editing scripts:

```bash
CPU_TEMP_ADDR=104 GPU_TEMP_ADDR=128 CPU_RPM_ADDR=200 GPU_RPM_ADDR=202 sudo ./ec_observe.sh watch
```
