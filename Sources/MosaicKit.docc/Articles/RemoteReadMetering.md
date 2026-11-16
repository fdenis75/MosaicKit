# Remote read metering

Log how many bytes are read from remote sources while MosaicKit processes them.

## Overview

A source is remote when it is an `http(s)` URL, or a file on a volume whose
`URLResourceValues.volumeIsLocal` is `false` (SMB, NFS, AFP, WebDAV). For each remote source,
every operation (`inspect`, `mosaic`, `mosaic-image`, `preview`) logs, in the `com.mosaicKit` /
`remote-io` OSLog category, the network bytes received, the share of the file size, the duration
and rate. A batch total is logged when the last operation ends.

Read the same data from ``RemoteReadLedger``: `records` (per operation) and `fileTotals`
(per file). Set `MOSAICKIT_REMOTE_IO=0` to disable.

## What is exact, what is estimated

AVFoundation does not report what it reads, so MosaicKit samples system counters:

- Network bytes are the 64-bit interface counters. They count all traffic the Mac received,
  including protocol overhead, so they are an upper bound for the file.
- When operations overlap, the growth between events is split equally between them. The batch
  total has no double counting; a per-file figure is exact only when `isolated` is true.
- Process disk reads (`proc_pid_rusage`) cover physical disks only, not SMB or NFS reads.
