#!/usr/bin/env python3
"""Drives the real whiptail interface through a real pseudo terminal."""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

script = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    # This is the terminal type that is unknown on a UGREEN NAS.
    os.environ["TERM"] = "xterm-ghostty"
    os.execvp("bash", ["bash", script])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
screen = b""


def wait_for(text, timeout=10):
    global screen
    deadline = time.time() + timeout
    while time.time() < deadline:
        if select.select([fd], [], [], 0.2)[0]:
            try:
                screen += os.read(fd, 65536)
            except OSError:
                break
        if text.encode() in screen:
            screen = b""
            return True
    print("did not see:", text)
    print(screen.decode(errors="replace")[-1500:])
    return False


def send(keys, pause=0.4):
    os.write(fd, keys.encode())
    time.sleep(pause)


DOWN = "\x1b[B"
ENTER = "\r"
TAB = "\t"


def finish():
    deadline = time.time() + 5
    while time.time() < deadline:
        finished, status = os.waitpid(pid, os.WNOHANG)
        if finished:
            print("EXIT", os.waitstatus_to_exitcode(status))
            sys.exit(os.waitstatus_to_exitcode(status))
        if select.select([fd], [], [], 0.2)[0]:
            try:
                os.read(fd, 65536)
            except OSError:
                pass
    print("program did not exit")
    os.kill(pid, 9)
    sys.exit(1)


if len(sys.argv) > 2 and sys.argv[2] == "--startup":
    if not wait_for("The schedule is not active"):
        sys.exit(1)
    send(ENTER)  # yes
    if not wait_for("Schedule active."):
        sys.exit(1)
    send(ENTER)
    if not wait_for("Schedule: active"):
        sys.exit(1)
    send(TAB + TAB + ENTER)
    finish()

if not wait_for("What do you want to do?"):
    sys.exit(1)
print("MAIN-MENU-OK")

if len(sys.argv) > 2 and sys.argv[2] == "--scrolling":
    send(ENTER)  # status, too long for one window
    if not wait_for("Tab, then Enter to close"):
        sys.exit(1)
    print("SCROLL-HINT-OK")
    send(TAB + ENTER)
    if not wait_for("What do you want to do?"):
        sys.exit(1)
    print("SCROLL-CLOSE-OK")
    send(TAB + TAB + ENTER)
    finish()

send(ENTER)  # status
if not wait_for("Virtual machines"):
    sys.exit(1)
print("STATUS-OK")
send(ENTER)  # close
wait_for("What do you want to do?")

send(DOWN + ENTER)  # jobs
wait_for("Create a job")
send(ENTER)  # new
wait_for("Job name")
send("Nightly" + ENTER)
wait_for("What should this job create?")
send(ENTER)  # backup
wait_for("Which VMs?")
send(ENTER)  # keep the default, all VMs
wait_for("How often?")
send(ENTER)  # keep the default, daily
wait_for("Start time")
send(ENTER)
wait_for("Keep at most this many")
send(ENTER)
wait_for("for at most this many days")
send(ENTER)
wait_for("Run this job on its schedule?")
send(ENTER)  # yes
wait_for("Job saved")
send(ENTER)
wait_for("Create a job")
send(TAB + TAB + ENTER)  # Cancel leaves the job list
wait_for("What do you want to do?")
send(TAB + TAB + ENTER)  # Cancel leaves the program

finish()
