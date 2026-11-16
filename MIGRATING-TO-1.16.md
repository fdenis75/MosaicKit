# Migrating to MosaicKit 1.16.0

This guide is for apps that already use MosaicKit 1.15.x. 1.16.0 adds remote read metering.
Nothing is removed or renamed. Output names do not change.

## 1. Do I need to change anything?

| If your app… | You are affected by | Severity |
|---|---|---|
| only processes local files | — | None |
| processes `https` URLs or files on SMB/NFS/AFP/WebDAV volumes | [2.1](#21-remote-read-metering) | Additive: new logs and optional API |

## 2. New behavior and API

### 2.1 Remote read metering

For a remote source, MosaicKit logs the bytes received while it was processed, per operation and
per batch, in the `com.mosaicKit` / `remote-io` OSLog category. New public API:
`RemoteSourceInfo`, `RemoteReadRecord`, `RemoteReadFileTotal` and `RemoteReadLedger.shared`
(`records`, `fileTotals`, `reset()`). Set `MOSAICKIT_REMOTE_IO=0` to disable it.

The numbers come from system counters, not from AVFoundation: interface byte counters include
other traffic and protocol overhead and are split equally between overlapping operations, so a
per-file figure is an estimate unless `isolated` is true. See ``RemoteReadMetering`` in DocC.
