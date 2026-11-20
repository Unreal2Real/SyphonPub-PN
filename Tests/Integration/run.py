"""Run fixture publishers and separate Syphon clients. Never opens QLab, PPT or a desktop stream."""
import argparse
import contextlib
import datetime
import json
import pathlib
import select
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
BIN = ROOT / "build" / "probes"
parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=["original", "continuous"])
parser.add_argument("--switches-only", action="store_true")
parser.add_argument("--soak", type=int, default=600)
args = parser.parse_args()
if args.soak < 1:
    parser.error("--soak must be positive")
name = "SyphonPub-QA-" + uuid.uuid4().hex
children = []
began = time.monotonic()

def log(test, **data):
    print(json.dumps(dict(test=test, mode=args.mode, elapsed=round(time.monotonic() - began, 3),
                          **data)), flush=True)

def spawn(command, **kwargs):
    process = subprocess.Popen(command, text=True, **kwargs)
    children.append(process)
    return process

def line(proc, timeout=10):
    if not select.select([proc.stdout], [], [], timeout)[0]:
        raise RuntimeError("Timed out awaiting publisher")
    return proc.stdout.readline().strip()

@contextlib.contextmanager
def sender():
    proc = spawn([BIN / args.mode, name], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        assert line(proc) == "READY", "Publisher unavailable"
        yield proc
    finally:
        if proc.poll() is None:
            command(proc, "quit", ack=False)
            proc.wait(timeout=5)

def command(proc, cmd, ack=True):
    proc.stdin.write(cmd + "\n")
    proc.stdin.flush()
    if ack:
        assert line(proc) == "OK " + cmd

def receiver(duration, resized=False, empty=False):
    return spawn([BIN / "receiver", name, "960" if resized else "1280",
                  "540" if resized else "720", str(int(resized)), str(duration)] + (["empty"] if empty else []),
                 stdout=subprocess.PIPE)

def result(proc, label, allow_static=False, timeout=8):
    output, _ = proc.communicate(timeout=timeout)
    data = json.loads(output)
    # A static publisher may remain silent after a correct first frame.
    # It must still satisfy the same first-pixel deadline as a continuous publisher.
    static_read = (allow_static and proc.returncode == 4 and data["pixel_checks"] >= 1
                   and 0 <= data["first_correct_ms"] <= 1000 and data["max_gap_ms"] > 1000)
    if proc.returncode == 0:
        outcome = "passed"
    elif static_read:
        outcome = "correct_first_frame_then_silent"
    elif data["first_correct_ms"] < 0:
        outcome = "missing_correct_first_frame"
    else:
        outcome = "failed"
    log(label, exit=proc.returncode, outcome=outcome, **data)
    if proc.returncode and not static_read:
        raise RuntimeError(f"{label} failed ({outcome})")
    return data

def sample(proc):
    fields = subprocess.check_output(["ps", "-p", str(proc.pid), "-o", "time=,rss="], text=True).split()
    cpu = sum(float(x) * 60 ** n for n, x in enumerate(reversed(fields[0].split(":"))))
    return time.monotonic(), cpu, int(fields[1])

def resources(proc, hold):
    record = []
    end = time.monotonic() + hold
    while True:
        t, cpu, rss = sample(proc)
        log("resource_sample", rss_KiB=rss, cpu_seconds=cpu)
        record.append((t, cpu, rss))
        if t >= end:
            break
        time.sleep(min(10, end-t))
    elapsed = record[-1][0] - record[0][0]
    log("resources", duration_s=round(elapsed, 3),
        mean_sender_cpu_pct=round(100*(record[-1][1] - record[0][1])/elapsed, 3),
        rss_KiB_start=record[0][2], rss_KiB_end=record[-1][2],
        rss_KiB_min=min(x[2] for x in record), rss_KiB_max=max(x[2] for x in record))

def run():
    log("configuration", local_time=datetime.datetime.now().astimezone().isoformat(), server=name,
        size="1280x720", fps=30, input="one synthetic BGRA frame unless explicitly changed")
    # The directory watcher is alive BEFORE the server. Measure connect-to-correct-pixel
    # once its Syphon server is discoverable. The sender has no cached image at first.
    before = receiver(2)
    time.sleep(.2)
    with sender() as proc:
        time.sleep(.25)
        command(proc, "page")
        result(before, "receiver_first", allow_static=args.mode == "original")
        time.sleep(30)
        late = receiver(.15)
        result(late, "first_after_30s_static", allow_static=args.mode == "original")
        if args.mode == "continuous":
            for i in range(10):
                result(receiver(.12), f"reconnect_{i+1}")
        # For fair resource sampling both paths have one connected observer. Give an
        # already attached original client a change to start its viewing interval.
        keeper = receiver(args.soak + 6)
        time.sleep(.25)
        command(proc, "page")
        time.sleep(.5)
        if args.mode == "continuous":
            result(receiver(.15), "second_concurrent_client")
        resources(proc, args.soak)
        result(keeper, "connected_observer", allow_static=args.mode == "original", timeout=12)
        command(proc, "resized")
        result(receiver(.15, resized=True), "new_page_and_resolution", allow_static=args.mode == "original")
        command(proc, "stop")
        # Try another injection after retire. A brand new receiver must never find it.
        if args.mode == "continuous":
            command(proc, "page")
            retired = receiver(.1)
            retired.wait(timeout=12)
            log("stopped_and_late_submit", receiver_exit=retired.returncode)
            assert retired.returncode == 2
def switches():
    assert args.mode == "continuous"
    log("switch_fixture", size="1280x720 → 960x540", frames="static")
    with sender() as proc:
        result(receiver(.6, empty=True), "no_frame_after_start")
        command(proc, "page")
        result(receiver(.15), "initial_page")
        command(proc, "60")
        rate = result(receiver(2), "fps_60")
        assert 100 <= rate["events"] <= 130
        command(proc, "off")
        static = result(receiver(2), "output_disabled", allow_static=True)
        assert static["first_correct_ms"] >= 0 and static["events"] <= 2
        new_size = receiver(.8, resized=True)
        time.sleep(.25)
        command(proc, "resized")
        result(new_size, "disabled_connected_client_sees_new_frame")
        command(proc, "on")
        rate = result(receiver(2, resized=True), "fps_30_after_resume")
        assert 50 <= rate["events"] <= 66
    # A fresh publisher has the SAME Syphon source name as a previous run.
    with sender() as proc:
        result(receiver(.6, empty=True), "no_old_texture_at_restart")
        command(proc, "page")
        result(receiver(.15), "restarted_page")
        command(proc, "stop")
        command(proc, "page")
        retired = receiver(.1)
        retired.wait(timeout=12)
        log("no_server_after_stop_and_late_submit", receiver_exit=retired.returncode)
        assert retired.returncode == 2
try:
    if args.switches_only:
        switches()
    else:
        run()
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
