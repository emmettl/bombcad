kind: fixed

**A Mac nearby that stops answering no longer holds a sweep or a pairing for ever.** Connecting
to a `nearby:` worker, TLS handshake and all, must finish within 20 seconds, and each message of
the first exchange within 30, or the connection is dropped with a message saying which Mac stopped
answering; checking a pairing code may take up to 5 minutes. Once a session has started, a run
takes as long as it takes. A Mac sharing its GPU now starts taking sessions with a new pairing's
key before it tells the other Mac the pairing holds, so a session opened straight after pairing no
longer reaches the listener being replaced.
