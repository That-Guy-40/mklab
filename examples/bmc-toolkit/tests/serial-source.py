#!/usr/bin/env python3
"""Test scaffolding: a deterministic 'node serial' on a TCP port.

Listens on 127.0.0.1:<port>; on each connection, streams a marker line every second
(explicit send, no buffering). Stands in for a real QEMU <serial type='tcp'> node so the
ipmi_sim SOL bridge can be tested without a VM boot-race. A real booting VM over this same
SOL path is shown in RUNBOOK.md / MANUAL_TESTING.md.

  serial-source.py <port> <marker>
"""
import socket, sys, time

def main():
    port, marker = int(sys.argv[1]), sys.argv[2]
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    while True:
        conn, _ = srv.accept()
        try:
            while True:
                conn.sendall(f"\r\n[{marker}] node serial tick\r\n".encode())
                time.sleep(1)
        except OSError:
            pass
        finally:
            conn.close()

if __name__ == "__main__":
    main()
