import os, pty, select, sys, time
prog, dic = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execv(prog, [prog, dic]); os._exit(1)
out = b""; t0 = time.time(); sent = False
while time.time() - t0 < 30:
    r,_,_ = select.select([fd], [], [], 0.5)
    if r:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        out += d
    if not sent and b"0 >" in out:
        sent = True; time.sleep(0.4); os.write(fd, b"\x04")
p2, st = os.waitpid(pid, os.WNOHANG)
alive = (p2 == 0)
if alive:
    os.kill(pid, 9); os.waitpid(pid, 0)
txt = out.decode(errors="replace")
print("ALIVE" if alive else "EXITED", "| prompts=%d" % txt.count("0 >"),
      "| exceptions=%d" % txt.count("Exception"), "| ff=%d" % txt.count("�"))
sys.exit(1 if alive or "Exception" in txt else 0)
