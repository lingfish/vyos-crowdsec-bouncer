#!/usr/bin/env python3
"""Drive the VyOS lab serial console over the domain's TCP chardev.

Usage:
  serial.py --tcp HOST PORT [--login USER PASS] [--password PASS]
            [--cmd 'cmd']... [--timeout SEC] [--idle-timeout SEC]

The domain's serial device is a raw TCP chardev (see lab/vyos-lab.xml), so
this connects with a plain socket and wraps it with pexpect.

Guest output is echoed to stdout; diagnostics go to stderr. If a
sudo-style password prompt appears while waiting for a shell prompt, it is
answered automatically (--password, falling back to the login password), so
`sudo -i` works unattended. A leftover shell from a previous session is
detected and reused instead of forcing a fresh login.
"""
import argparse
import re
import socket
import sys

import pexpect
import pexpect.fdpexpect

LOGIN = re.compile(rb"login:\s*$")
PASSW = re.compile(rb"[Pp]assword[^:]*:\s*$")
PROMPT = re.compile(rb"[\w.-]+@[\w.-]+(:[^\r\n#$]*)?[#$]\s*$")


def diag(msg: str) -> None:
    sys.stderr.write("[serial] %s\n" % msg)
    sys.stderr.flush()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tcp", nargs=2, metavar=("HOST", "PORT"), required=True)
    ap.add_argument("--login", nargs=2, metavar=("USER", "PASS"))
    ap.add_argument("--password", help="answer for sudo-style password prompts")
    ap.add_argument("--cmd", action="append", default=[], metavar="CMD")
    ap.add_argument("--timeout", type=float, default=600, help="boot/login budget")
    ap.add_argument("--idle-timeout", type=float, default=90, help="max silence per step")
    args = ap.parse_args()

    sudo_pass = args.password or (args.login[1] if args.login else None)
    host, port = args.tcp
    s = socket.create_connection((host, int(port)), timeout=10)
    child = pexpect.fdpexpect.fdspawn(s.fileno(), encoding=None)
    child.delaybeforesend = 0
    child.logfile_read = sys.stdout.buffer

    def die(msg: str) -> None:
        diag("FATAL: %s" % msg)
        sys.exit(1)

    def expect(patterns, step: str, timeout: float) -> int:
        try:
            return child.expect(patterns, timeout=timeout)
        except pexpect.TIMEOUT:
            die("timeout %.0fs waiting for %s" % (timeout, step))
        except pexpect.EOF:
            die("connection closed while waiting for %s" % step)
        return -1

    child.send(b"\r")  # wake a leftover shell or idle getty
    at_prompt = False

    if args.login:
        idx = expect([LOGIN, PROMPT], "login prompt", args.timeout)
        if idx == 0:  # fresh login
            child.send((args.login[0] + "\r").encode())
            expect(PASSW, "password prompt", args.timeout)
            child.send((args.login[1] + "\r").encode())
            at_prompt = False
            diag("sent login credentials")
        else:  # leftover shell already present
            at_prompt = True
            diag("already in shell, skipping login")
    else:
        expect(PROMPT, "shell prompt", args.timeout)
        at_prompt = True

    for c in args.cmd:
        while not at_prompt:
            idx = expect([PROMPT, PASSW], "shell prompt", args.idle_timeout)
            if idx == 0:
                at_prompt = True
            else:
                child.send((sudo_pass + "\r").encode())
                diag("sent password")
        child.send((c + "\r").encode())
        diag("sent: %s" % c)
        at_prompt = False

    while not at_prompt:
        idx = expect([PROMPT, PASSW], "final prompt", args.idle_timeout)
        if idx == 0:
            break
        child.send((sudo_pass + "\r").encode())
    diag("done")
    sys.exit(0)


if __name__ == "__main__":
    main()