#!/usr/bin/env python3
"""Move the pin(s) of one image in env-config-virtualmachine.yaml.

Images are registered under a versioned name and never replaced (see
register-image.sh), so a new build takes effect only once its pin is moved.
This does that edit for the release workflow.

Which entries move: every entry under harvester.images whose imageId, with any
version suffix stripped, is IMAGE_NAME. That is how aliases follow their image
-- `ubuntu24` points at u26-dev, so it moves when u26-dev is rebuilt -- without
a mapping to keep in sync. If no entry matches, one is added under IMAGE_NAME.

The file is edited line by line rather than round-tripped through a YAML
library, so its comments and column alignment survive untouched.

Required env:
  IMAGE_NAME     unversioned image name (e.g. u26-dev)
  IMAGE_ID       new imageId, <namespace>/<vmi name> (e.g. default/u26-dev-26.928.1200)
  STORAGE_CLASS  the new image's Longhorn class (lh-<uuid>)
Optional:
  PIN_FILE       default: the crossplane-mgmt pin file, relative to packer/_build
"""
import os
import re
import sys

PIN_FILE = os.environ.get(
    "PIN_FILE",
    "../../clusters/crossplane-mgmt/platform/virtual-machine/env-config-virtualmachine.yaml",
)
# Same version shape prune-images.sh recognises: -<YY.MDD.HHMM>, optionally pr<N>.
VERSION_RE = re.compile(r"^(.+)-((pr[0-9]+\.)?[0-9]{2}\.[0-9]{3,4}\.[0-9]{4})$")


def env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"ERROR: {name} is required")
    return value


def base_of(image_id):
    name = image_id.split("/", 1)[-1]
    m = VERSION_RE.match(name)
    return m.group(1) if m else name


def main():
    image = env("IMAGE_NAME")
    image_id = env("IMAGE_ID")
    storage_class = env("STORAGE_CLASS")

    with open(PIN_FILE) as f:
        lines = f.read().split("\n")

    # Locate the images: block and its entries. An entry is a key line one
    # level below images:, followed by its imageId / storageClassName lines.
    start = next((i for i, l in enumerate(lines) if re.match(r"^\s+images:\s*(#.*)?$", l)), None)
    if start is None:
        sys.exit(f"ERROR: no 'images:' block in {PIN_FILE}")
    block_indent = len(lines[start]) - len(lines[start].lstrip())

    end = start + 1
    while end < len(lines):
        l = lines[end]
        if l.strip() and not l.lstrip().startswith("#") and len(l) - len(l.lstrip()) <= block_indent:
            break
        end += 1

    value_re = re.compile(r"^(\s+(imageId|storageClassName):\s*)(\S+)(.*)$")
    moved = []
    entry_indent = None
    for i in range(start + 1, end):
        m = value_re.match(lines[i])
        if not m or m.group(2) != "imageId" or base_of(m.group(3)) != image:
            if entry_indent is None and re.match(r"^\s+[^\s#][^:]*:\s*(#.*)?$", lines[i]):
                entry_indent = len(lines[i]) - len(lines[i].lstrip())
            continue
        old_id = m.group(3)
        lines[i] = f"{m.group(1)}{image_id}{m.group(4)}"
        # The storageClassName belongs to the same entry: the next value line.
        for j in range(i + 1, end):
            n = value_re.match(lines[j])
            if n and n.group(2) == "storageClassName":
                lines[j] = f"{n.group(1)}{storage_class}{n.group(4)}"
                break
            if n and n.group(2) == "imageId":
                sys.exit(f"ERROR: entry for {old_id} has no storageClassName")
        key = next(
            lines[k].strip().split(":")[0]
            for k in range(i - 1, start, -1)
            if re.match(r"^\s+[^\s#][^:]*:\s*(#.*)?$", lines[k])
        )
        moved.append((key, old_id))

    if not moved:
        # Nothing pins this image yet: add it under its own name, after the
        # last line of the block that belongs to an entry.
        indent = " " * (entry_indent if entry_indent is not None else block_indent + 2)
        last = end - 1
        while last > start and (not lines[last].strip() or lines[last].lstrip().startswith("#")):
            last -= 1
        lines[last + 1:last + 1] = [
            f"{indent}{image}:",
            f"{indent}  imageId: {image_id}",
            f"{indent}  storageClassName: {storage_class}",
        ]
        print(f"added   {image}: {image_id} ({storage_class})")
    else:
        for key, old_id in moved:
            print(f"moved   {key}: {old_id} -> {image_id} ({storage_class})")

    with open(PIN_FILE, "w") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    main()
