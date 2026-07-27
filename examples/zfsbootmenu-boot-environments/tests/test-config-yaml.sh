#!/usr/bin/env bash
# test-config-yaml.sh — the example generate-zbm config.yaml must be valid YAML
# and carry the keys generate-zbm needs to build a bootable EFI on Debian.
# Host-safe: static parse, no ZBM, no ZFS.
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
arm_exit_trap

require_cmd python3
python3 -c 'import yaml' 2>/dev/null || skip "python3 yaml module (PyYAML) not available"

CFG="$LAB_DIR/config.yaml"
[[ -r "$CFG" ]] || fail "config.yaml not found at $CFG"

# One embedded validator: parse + assert the structure generate-zbm relies on.
python3 - "$CFG" <<'PY' || fail "config.yaml failed validation (see message above)"
import sys, yaml
p = sys.argv[1]
try:
    with open(p) as f:
        cfg = yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f"  - invalid YAML: {e}", file=sys.stderr); sys.exit(1)

def need(cond, msg):
    if not cond:
        print(f"  - {msg}", file=sys.stderr); sys.exit(1)

need(isinstance(cfg, dict), "top level is not a mapping")
need("Global" in cfg, "missing top-level 'Global'")
need(cfg["Global"].get("ManageImages") is True,
     "Global.ManageImages must be true or generate-zbm won't build images")
need(isinstance(cfg["Global"].get("BootMountPoint"), str),
     "Global.BootMountPoint (the ESP) must be set")
# Something must actually be produced: the unified EFI and/or the kernel pair.
efi_on  = cfg.get("EFI", {}).get("Enabled") is True
comp_on = cfg.get("Components", {}).get("Enabled") is True
need(efi_on or comp_on,
     "neither EFI.Enabled nor Components.Enabled is true — generate-zbm would emit nothing")
if efi_on:
    need(isinstance(cfg["EFI"].get("ImageDir"), str), "EFI.ImageDir must be set when EFI is enabled")
need(isinstance(cfg.get("Kernel", {}).get("CommandLine"), str),
     "Kernel.CommandLine (ZBM's own cmdline) must be set")
print("  - valid YAML; ManageImages=true; EFI output enabled; ESP + cmdline present", file=sys.stderr)
PY

pass "config.yaml is valid and carries the keys generate-zbm needs for a Debian EFI build"
