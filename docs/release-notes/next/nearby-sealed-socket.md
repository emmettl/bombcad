kind: changed

**A run on a Mac nearby shows two and a half to six times as many frames over Wi-Fi.** A session's
frames and results now go on a plain socket beside its encrypted connection, sealed with keys
from the pairing (AES-GCM, a fresh key each way each session), since macOS's network framework
carried frames at 4 to 7 MB/s where the same Wi-Fi carries 40. Measured with the mini watching the
Studio on 22 October 2026: 40 to 45 MB/s back and 34 to 38 out, and the city block at every 2nd
cell showed 99 to 161 of 171 frames instead of 30 to 55. If the socket cannot be opened the session goes on
the encrypted connection as before; `BombCAD nearby probe <Mac>` measures both. Both Macs need
this version (worker protocol 17). See
[Macs nearby](../../distributed-computing.md#the-bulk-on-a-socket-and-the-thin-clients-controls-22-october-2026).
