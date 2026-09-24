#!/usr/bin/env python3
"""Verify/import a host-only XCFramework. No device or network operations."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            result.update(chunk)
    return result.hexdigest()


def fingerprint(files):
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def read_json(path):
    if path.is_symlink() or path.stat().st_size > 1024 * 1024:
        raise ValueError("Unsafe or oversized renderer metadata")
    return json.loads(path.read_text())


def pin_for(record):
    return {"schema": 1, "abi": record["abi"], "sourceSHA256": record["source"]["sha256"],
            "artifactSHA256": record["artifactSHA256"]}


def input_list(record):
    paths = {"PIN.json", "PROVENANCE.json", "RendererInputs.xcfilelist", "PocketUIHost.xcframework"}
    for name in record["artifactFiles"]:
        path = Path("PocketUIHost.xcframework") / name
        paths.add(str(path))
        paths.update(str(parent) for parent in path.parents if str(parent) != ".")
    return "".join("$(SRCROOT)/Support/PocketUIHost/" + name + "\n" for name in sorted(paths))


def verify(directory, require_pin=True):
    if directory.is_symlink():
        raise ValueError("Renderer directory cannot be a symlink")
    record = read_json(directory / "PROVENANCE.json")
    if record.get("schema") != 1 or record.get("abi") != 1:
        raise ValueError("Unsupported renderer provenance/ABI")
    if fingerprint(record["source"]["files"]) != record["source"]["sha256"]:
        raise ValueError("Invalid renderer source manifest")
    if require_pin and read_json(directory / "PIN.json") != pin_for(record):
        raise ValueError("Renderer does not match the accepted pin")
    package = directory / "PocketUIHost.xcframework"
    if package.is_symlink() or not package.is_dir():
        raise ValueError("Missing/unsafe host XCFramework")
    files = {}
    total = 0
    for path in sorted(package.rglob("*")):
        if path.is_symlink():
            raise ValueError("Renderer package contains a symlink")
        if path.is_file():
            total += path.stat().st_size
            if total > 64 * 1024 * 1024:
                raise ValueError("Renderer artifact exceeds64MiB")
            files[str(path.relative_to(package))] = digest(path)
    if files != record["artifactFiles"] or fingerprint(files) != record["artifactSHA256"]:
        raise ValueError("Renderer artifact is missing or changed")
    if "Info.plist" not in files or not any(name.endswith("/libpdui_host.a") for name in files):
        raise ValueError("Not a host renderer XCFramework")
    if require_pin and (directory / "RendererInputs.xcfilelist").read_text() != input_list(record):
        raise ValueError("Renderer sandbox inputs do not match the accepted artifact")
    return record


def import_artifact(root, source):
    firmware = root.parent / "pocket-daily-firmware"
    subprocess.run(["python3", str(firmware / "host/build_apple.py"), "--verify", str(source)], check=True)
    record = verify(source, require_pin=False)
    destination = root / "Support/PocketUIHost"
    if destination.exists():
        current = verify(destination, require_pin=False)
        if read_json(destination / "PIN.json") != pin_for(current):
            raise ValueError("Existing renderer pin changed")
        if pin_for(current) == pin_for(record) and (destination / "RendererInputs.xcfilelist").exists():
            verify(destination)
            print("Accepted renderer is already installed.")
            return
    staged = Path(tempfile.mkdtemp(prefix=".host-renderer-", dir=root / "Support"))
    # Retain failed staging directories for diagnosis; never delete user files.
    shutil.copytree(source / "PocketUIHost.xcframework", staged / "PocketUIHost.xcframework")
    shutil.copyfile(source / "PROVENANCE.json", staged / "PROVENANCE.json")
    (staged / "PIN.json").write_text(json.dumps(pin_for(record), indent=2, sort_keys=True) + "\n")
    (staged / "RendererInputs.xcfilelist").write_text(input_list(record))
    verify(staged)
    subprocess.run(["python3", str(firmware / "host/build_apple.py"), "--verify", str(source)], check=True)
    backup = None
    if destination.exists():
        backups = root / ".build/host-renderer-backups"
        backups.mkdir(parents=True, exist_ok=True)
        backup = backups / str(uuid.uuid4())
        destination.rename(backup)
    try:
        staged.rename(destination)
    except OSError:
        if backup is not None:
            backup.rename(destination)
        raise
    print("Imported verified host renderer: " + str(destination))
    if backup is not None:
        print("Previous artifact preserved: " + str(backup))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["verify", "import"])
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    if args.action == "verify":
        verify(args.directory)
        print("Accepted host renderer verified.")
    else:
        import_artifact(Path(__file__).resolve().parent.parent, args.directory.resolve())


if __name__ == "__main__":
    main()
