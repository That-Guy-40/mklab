# Upstream provenance — cite, don't mirror

Per the repo's vendoring convention (CLAUDE.md): a lab built from **one specific
tutorial page** vendors that page byte-exact; a lab that follows **official,
multi-page documentation / upstream code** *cites* it with a retrieved date and
does **not** mirror whole doc-sites. This lab is the second kind — it synthesizes
the LinuxBoot mechanic from the projects' own docs and source, not from a single
how-to. So there is **nothing vendored here**, only the citations below.

All URLs **retrieved 2026-06-30** and resolved 200 at that time.

| What we used it for | Source | URL |
|---|---|---|
| The concept (firmware → Linux → kexec the OS) | **LinuxBoot** project site | <https://www.linuxboot.org/> |
| The userland: the Go `init`-as-bootloader, `kexec`/`localboot`/`pxeboot`, `-build=bb`, `-uinitcmd`, `-files` | **u-root** (source + README), pinned tag **v0.14.0** | <https://github.com/u-root/u-root> / <https://github.com/u-root/u-root/tree/v0.14.0> |
| The Tier B packaging: PE sections `.linux/.initrd/.cmdline/.osrel`, the EFI stub, `ukify` | **systemd** Unified Kernel Image spec + `ukify`/`systemd-stub` man pages | <https://uapi-group.org/specifications/specs/unified_kernel_image/> · <https://www.freedesktop.org/software/systemd/man/latest/ukify.html> · <https://www.freedesktop.org/software/systemd/man/latest/systemd-stub.html> |
| EFISTUB + the `initrd=`/LoadFile2 initrd mechanism | Linux kernel docs — *EFI stub* | <https://www.kernel.org/doc/html/latest/admin-guide/efi-stub.html> |
| The kexec syscalls (`kexec_file_load` vs `kexec_load`, the `-L` fallback) | `kexec-tools` + kernel kexec docs | <https://man7.org/linux/man-pages/man8/kexec.8.html> |
| Tier A (planned): coreboot ROM + LinuxBoot payload, `crossgcc`, `cbfstool` | **coreboot** docs | <https://doc.coreboot.org/> |
| The AlmaLinux 9 pxeboot `vmlinuz` we boot/kexec | AlmaLinux mirror | <https://repo.almalinux.org/almalinux/9/BaseOS/x86_64/os/images/pxeboot/vmlinuz> |

**Versions pinned in the lab:** u-root **v0.14.0** (`build-uroot.sh` `UROOT_REF`),
Go **1.22** (apt `golang-go`, with `GOTOOLCHAIN=local`), systemd **255**
(`ukify`/stub, deb-extracted by `deps.sh`), AlmaLinux **9** kernel
(`fetch-kernel.sh`).

No images, JS, fonts, or CSS are archived — these are living documentation sites;
follow the links for the authoritative, current versions. If a future variant of
this lab follows **one specific** coreboot+LinuxBoot QEMU how-to page, vendor *that
page* byte-exact here (HTML + CSS + provenance table + sha256), per the first-tier
convention.
