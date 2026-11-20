"""Check a persistent Syphon client and two clients that join mid-transition.
Build first with Tests/Integration/build-probes.sh. Only synthetic QA sources are used.
"""
import contextlib
import pathlib
import select
import subprocess
import uuid

BIN = pathlib.Path(__file__).resolve().parents[2] / "build/probes"
name = "SyphonPub-QA-" + uuid.uuid4().hex
children = []


def start(executable, *args):
    process = subprocess.Popen([BIN / executable, name, *args], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, bufsize=0)
    children.append(process)
    return process


def read(process, timeout=1):
    if not select.select([process.stdout], [], [], timeout)[0]:
        raise TimeoutError("No expected Syphon frame or reply")
    return process.stdout.readline().decode().strip()


def expect(process, message, timeout=1):
    actual = read(process, timeout)
    if actual != message:
        raise AssertionError(f"Expected {message}, received {actual}")


def send(cmd):
    sender.stdin.write((cmd + "\n").encode())
    expect(sender, "OK " + cmd)


def steady(process, seconds=.35):
    if select.select([process.stdout], [], [], seconds)[0]:
        raise AssertionError("Unexpected pixel transition: " + read(process))


try:
    sender = start("continuous")
    expect(sender, "READY", 10)
    send("wait")
    observer = start("receiver", "follow")
    server = read(observer, 5)
    assert server.startswith("SERVER ") and server != "SERVER (null)"
    expect(observer, "BLACK 1280x720")
    send("attachA")
    send("pageA")
    expect(observer, "A 1280x720")
    send("endA")
    expect(observer, "BLACK 1280x720")
    send("lateA")
    steady(observer)
    gap_client = start("receiver", "follow")
    expect(gap_client, server, 5)
    expect(gap_client, "BLACK 1280x720")
    send("attachB")
    send("endA")  # Late terminal callback from A while B is attached.
    send("lateA")
    steady(observer)
    send("pageB")
    expect(observer, "B 960x540")
    expect(gap_client, "B 960x540")
    send("endA")
    send("lateA")
    steady(observer)
    late_client = start("receiver", "follow")
    expect(late_client, server, 5)
    expect(late_client, "B 960x540")
    send("endB")
    expect(observer, "BLACK 960x540")
    expect(late_client, "BLACK 960x540")
    send("verifyB")
    print(f"{server}; persistent client BLACK -> A -> BLACK -> B -> BLACK (B size); "
          "client joining gap BLACK -> B; late client B; same server UUID on all clients; "
          "old frame and terminal callbacks ignored; two actual ready notifications.")
finally:
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
        with contextlib.suppress(subprocess.TimeoutExpired):
            child.wait(timeout=2)
