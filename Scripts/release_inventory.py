#!/usr/bin/env python3
"""Read-only, fail-closed inventory; release verification helper."""
import hashlib, json, os, stat, sys
from pathlib import Path

def stamp(s):
    return (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)

def file_record(path, before):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or stamp(opened) != stamp(before):
            raise RuntimeError("Inventory input changed before open")
        h = hashlib.sha256()
        while True:
            block = os.read(fd, 1048576)
            if not block: break
            h.update(block)
        if stamp(os.fstat(fd)) != stamp(opened) or stamp(os.lstat(path)) != stamp(opened):
            raise RuntimeError("Inventory input changed while hashing")
        return h.hexdigest()
    finally:
        os.close(fd)

def inventory(roots):
    result = {}
    for label, value in roots.items():
        root = Path(value)
        try: root.lstat()
        except FileNotFoundError:
            result[label] = {"state": "missing"}; continue
        records = {}
        def visit(path):
            before = path.lstat()
            kind = "file" if stat.S_ISREG(before.st_mode) else "directory" if stat.S_ISDIR(before.st_mode) else "unsupported"
            if kind == "unsupported":
                raise RuntimeError("Inventory cannot prove symlink or special-file contents")
            item = {"kind": kind, "device":before.st_dev, "inode":before.st_ino, "mode":before.st_mode,
                    "size":before.st_size, "mtimeNS":before.st_mtime_ns, "ctimeNS":before.st_ctime_ns}
            key = "." if path == root else path.relative_to(root).as_posix()
            if kind == "file": item["sha256"] = file_record(path, before)
            else:
                for child in sorted(path.iterdir()): visit(child)
                if stamp(path.lstat()) != stamp(before):
                    raise RuntimeError("Inventory directory changed while scanning")
            records[key] = item
        visit(root)
        result[label] = {"state":"present", "nodes":records}
    return result

if __name__ == "__main__":
    if len(sys.argv) < 3: raise SystemExit("Usage: release_inventory.py OUTPUT LABEL=PATH [LABEL=PATH ...]")
    roots = dict(arg.split("=", 1) for arg in sys.argv[2:])
    output = Path(sys.argv[1])
    if output.exists(): raise SystemExit("Refusing to overwrite an inventory")
    data = {"schemaVersion":1,"scope":"Regular files and directories; symlinks/special files/races fail closed", "roots":inventory(roots)}
    with output.open("x") as f: json.dump(data, f, sort_keys=True, indent=2); f.write("\n")
