#!/usr/bin/env python3
"""Bring pip's vendored dependency tree up to patched versions.

pip bundles its own copies of a handful of libraries under ``pip/_vendor`` and
describes them in two manifests -- ``vendor.txt`` and ``bom.cdx.json`` (a
CycloneDX SBOM, added in pip 26). Scanners read those manifests, so a fix has to
update both or the tree keeps reporting versions it no longer ships.

msgpack (GHSA-6v7p-g79w-8964)
    Out-of-bounds read when an ``Unpacker`` is reused after a caught error. Real
    code, imported by pip's own HTTP cache (``_vendor/cachecontrol/serialize``),
    so it is re-vendored from the patched msgpack installed system-wide. pip
    applies no import rewriting to this package -- its modules use relative
    imports only -- so upstream's files drop straight in.

setuptools (CVE-2025-47273)
    Path traversal in ``setuptools.package_index.PackageIndex``. pip vendors
    only ``pkg_resources``, never ``package_index``, and pip itself declares the
    ``pkg_resources`` metadata backend unusable on Python 3.14+ (see
    ``pip/_internal/metadata/__init__.py``). The tree is dead code here, so it is
    deleted rather than suppressed. The real setuptools is installed separately
    and current.
"""

import json
import os
import shutil

import msgpack
import pip._vendor

# GHSA-6v7p-g79w-8964; the image pins this floor at install time too.
MSGPACK_FIXED_IN = (1, 2, 1)

vendor = os.path.dirname(pip._vendor.__file__)
version = msgpack.__version__
assert msgpack.version >= MSGPACK_FIXED_IN, f"msgpack {version} is still affected"

# ---- re-vendor msgpack, drop the dead pkg_resources tree ----
shutil.rmtree(os.path.join(vendor, "msgpack"))
shutil.copytree(os.path.dirname(msgpack.__file__), os.path.join(vendor, "msgpack"))
shutil.rmtree(os.path.join(vendor, "pkg_resources"), ignore_errors=True)

# ---- vendor.txt ----
vendor_txt = os.path.join(vendor, "vendor.txt")
with open(vendor_txt) as fh:
    lines = fh.readlines()
with open(vendor_txt, "w") as fh:
    for line in lines:
        if line.strip().startswith("setuptools=="):
            continue
        if line.strip().startswith("msgpack=="):
            line = f"msgpack=={version}\n"
        fh.write(line)

# ---- bom.cdx.json (pip >= 26) ----
bom_path = os.path.join(vendor, "bom.cdx.json")
if os.path.exists(bom_path):
    with open(bom_path) as fh:
        bom = json.load(fh)

    old_ref, new_ref = None, f"pkg:pypi/msgpack@{version}"
    components = []
    for component in bom.get("components", []):
        if component.get("name") == "setuptools":
            continue
        if component.get("name") == "msgpack":
            old_ref = component["bom-ref"]
            component["version"] = version
            component["bom-ref"] = component["purl"] = new_ref
        components.append(component)
    bom["components"] = components

    def retarget(ref):
        return new_ref if ref == old_ref else ref

    def is_setuptools(ref):
        return ref.startswith("pkg:pypi/setuptools@")

    dependencies = []
    for dependency in bom.get("dependencies", []):
        ref = dependency.get("ref", "")
        if is_setuptools(ref):
            continue
        dependency["ref"] = retarget(ref)
        if "dependsOn" in dependency:
            dependency["dependsOn"] = [
                retarget(r) for r in dependency["dependsOn"] if not is_setuptools(r)
            ]
        dependencies.append(dependency)
    bom["dependencies"] = dependencies

    with open(bom_path, "w") as fh:
        json.dump(bom, fh, indent=2, sort_keys=True)

# ---- neither manifest may still advertise what the tree no longer ships ----
for manifest in (vendor_txt, bom_path):
    if not os.path.exists(manifest):
        continue
    with open(manifest) as fh:
        blob = fh.read()
    assert "setuptools" not in blob, f"stale setuptools entry in {manifest}"
    assert "msgpack" in blob, f"lost the msgpack entry in {manifest}"
    assert version in blob, f"{manifest} does not report msgpack {version}"

print(f"pip vendored tree patched: msgpack {version}, pkg_resources removed")
