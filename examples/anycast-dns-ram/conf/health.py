#!/usr/bin/env python3
# ExaBGP health-gate: announce the anycast VIP only WHILE the local DNS answers;
# withdraw it the moment DNS stops. This is the whole point of anycast — a node
# advertises the service address only while it can actually serve it.
import subprocess, sys, time

VIP = "10.89.7.100/32"
NH  = "10.89.7.10"     # this node's real address (BGP next-hop)

def emit(line):
    sys.stdout.write(line + "\n"); sys.stdout.flush()
def log(msg):
    sys.stderr.write("HEALTH: " + msg + "\n"); sys.stderr.flush()

def healthy():
    try:
        r = subprocess.run(
            ["dig", "+short", "+time=1", "+tries=1", "@127.0.0.1",
             "example.lab", "SOA"],
            capture_output=True, timeout=3)
        return r.returncode == 0 and r.stdout.strip() != b""
    except Exception:
        return False

# let the BGP session establish before the first advertisement
time.sleep(3)
state = None
while True:
    up = healthy()
    if up and state is not True:
        emit("announce route %s next-hop %s" % (VIP, NH))
        log("up -> announced %s" % VIP)
        state = True
    elif (not up) and state is not False:
        emit("withdraw route %s next-hop %s" % (VIP, NH))
        log("down -> withdrew %s" % VIP)
        state = False
    time.sleep(2)
