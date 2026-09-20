#!/usr/bin/env python3
import os, pty, time, select, re, fcntl, termios, struct, sys
ROWS, COLS = 40, 118
seq = sys.argv[1] if len(sys.argv) > 1 else ""
env = dict(os.environ, TERM="xterm-256color", LINES=str(ROWS), COLUMNS=str(COLS), FT_NO_WTFIX="1")
pid, fd = pty.fork()
if pid == 0:
    os.chdir(os.path.dirname(os.path.abspath(__file__)) + "/..")
    os.execvpe("bash", ["bash", "demo/css-demo.bash"], env); os._exit(1)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
grid = [[" "]*COLS for _ in range(ROWS)]; row = col = 0
osc = re.compile(r'\][0-9]*;[^\x07\x1b]*(\x07|\x1b\\)'); csi = re.compile(r'\[([0-9;?]*)([A-Za-z])'); pending = ""
def feed(data):
    global row, col, pending
    data = pending + data; pending = ""; i = 0
    while i < len(data):
        c = data[i]
        if c == "\x1b":
            if i+1 >= len(data): pending = data[i:]; return
            if data[i+1] == "]":
                m = osc.match(data, i+1)
                if m: i = m.end(); continue
                pending = data[i:]; return
            m = csi.match(data, i+1)
            if m:
                if m.group(2) == "H":
                    n = [int(x) for x in m.group(1).split(";") if x != ""] or [1,1]
                    row = max(0,(n[0] if n else 1)-1); col = max(0,(n[1] if len(n)>1 else 1)-1)
                i = m.end(); continue
            i += 2; continue
        if c == "\r": col = 0; i += 1; continue
        if c == "\n": row = min(ROWS-1, row+1); i += 1; continue
        if ord(c) < 32: i += 1; continue
        if 0 <= row < ROWS and 0 <= col < COLS: grid[row][col] = c
        col += 1; i += 1
def pump(t):
    end = time.time()+t
    while time.time() < end:
        r,_,_ = select.select([fd],[],[],0.05)
        if r:
            try: d = os.read(fd, 65536)
            except OSError: return
            if not d: return
            feed(d.decode("utf-8","replace"))
def dump(tag):
    print(f"\n===== {tag} =====")
    for r in range(ROWS):
        ln = "".join(grid[r]).rstrip()
        if ln: print(f"{r:2}|{ln}")
def sgr(kind, col, row):
    b={"press":0,"drag":32,"rel":0}[kind]; fin="m" if kind=="rel" else "M"
    return f"\x1b[<{b};{col};{row}{fin}".encode()
def key(k):
    m={"PGDN":"\x1b[6~","TAB":"\t","ENTER":"\r","SP":" ","DOWN":"\x1b[B","UP":"\x1b[A"}
    return m.get(k,k).encode()
pump(3.5); dump("initial")
for part in seq.split(","):
    part=part.strip()
    if not part: continue
    tok=part.split()
    if tok[0] in ("press","drag","rel"):
        os.write(fd, sgr(tok[0], int(tok[1]), int(tok[2]))); pump(float(tok[3]) if len(tok)>3 else 0.4); dump(part); continue
    secs=float(tok[-1]) if re.match(r"^[0-9.]+$",tok[-1]) else 0.4
    ks=tok[:-1] if re.match(r"^[0-9.]+$",tok[-1]) else tok
    for k in ks: os.write(fd,key(k))
    pump(secs); dump(part)
os.write(fd, b"q"); pump(0.3)
