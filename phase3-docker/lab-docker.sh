#!/usr/bin/env bash
# lab-docker.sh — Phase 3 of LAB_CREATE_V2: Docker container & topology mgmt.
#
# Backends   : image       — pull / use an existing image
#              from-chroot — `docker import` a Phase-1 chroot tarball as a single-layer image
#              build       — `docker buildx build` (multi-arch via qemu-user-static)
# Arches     : x86_64 aarch64 armv7l ppc64le riscv64 s390x  (mapped to docker platforms)
# Topologies : multi-service via TOML, with declared networks + per-service options
# Config     : CLI flags or TOML (--config FILE)
#
# Self-contained per the per-phase rule: helpers from earlier phases are
# duplicated inline. Do not source files from sibling phases.
#
# Lab ownership is tracked on the docker side via labels:
#   lab-create.tool = lab-docker
#   lab-create.lab  = <lab-name>
#   lab-create.svc  = <service-name>
# `down`/`destroy`/`list` operate by querying these labels — no separate
# state file is the source of truth.

set -euo pipefail
shopt -s nullglob

readonly LAB_VERSION="0.1.0"
readonly LAB_PROG="${0##*/}"
readonly LAB_LABEL_TOOL="lab-create.tool=lab-docker"
readonly LAB_LABEL_LAB="lab-create.lab"
readonly LAB_LABEL_SVC="lab-create.svc"

# ─── Logging ────────────────────────────────────────────────────────────────
LAB_LOG_LEVEL="${LAB_LOG_LEVEL:-info}"
_log() {
    local level="$1"; shift
    local prio cur
    case "$level" in debug) prio=0;; info) prio=1;; warn) prio=2;; error) prio=3;; esac
    case "$LAB_LOG_LEVEL" in debug) cur=0;; info) cur=1;; warn) cur=2;; error) cur=3;; *) cur=1;; esac
    [[ $prio -lt $cur ]] && return 0
    local color reset
    if [[ -t 2 ]]; then
        case "$level" in
            debug) color=$'\033[2m' ;;
            info)  color=$'\033[36m' ;;
            warn)  color=$'\033[33m' ;;
            error) color=$'\033[31m' ;;
        esac
        reset=$'\033[0m'
    else
        color=""; reset=""
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}
log_debug() { _log debug "$@"; }
log_info()  { _log info  "$@"; }
log_warn()  { _log warn  "$@"; }
log_error() { _log error "$@"; }
die()       { _log error "$@"; exit 1; }

# ─── Host / arch detection ──────────────────────────────────────────────────
detect_host_distro() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s' "${ID:-unknown}" )
    else
        printf 'unknown'
    fi
}

detect_host_arch() {
    case "$(uname -m)" in
        x86_64|amd64)         printf 'x86_64' ;;
        aarch64|arm64)        printf 'aarch64' ;;
        armv7l|armv7|armhf)   printf 'armv7l' ;;
        ppc64le|powerpc64le)  printf 'ppc64le' ;;
        riscv64)              printf 'riscv64' ;;
        s390x)                printf 's390x' ;;
        *)                    printf 'unknown' ;;
    esac
}

is_known_arch() {
    case "$1" in
        x86_64|aarch64|armv7l|ppc64le|riscv64|s390x) return 0 ;;
        *) return 1 ;;
    esac
}

docker_platform() {
    # canonical → docker platform spec
    case "$1" in
        x86_64)  printf 'linux/amd64' ;;
        aarch64) printf 'linux/arm64' ;;
        armv7l)  printf 'linux/arm/v7' ;;
        ppc64le) printf 'linux/ppc64le' ;;
        riscv64) printf 'linux/riscv64' ;;
        s390x)   printf 'linux/s390x' ;;
        *) return 1 ;;
    esac
}

# ─── Dependency probing ─────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

install_hint() {
    local tool="$1"
    local host; host="$(detect_host_distro)"
    case "$host" in
        debian|ubuntu|kali) printf 'sudo apt-get install -y %s' "$tool" ;;
        rocky|rhel|fedora|almalinux) printf 'sudo dnf install -y %s' "$tool" ;;
        *) printf '(install %q via your package manager)' "$tool" ;;
    esac
}

require_cmd() {
    local tool="$1"
    have "$tool" || die "$tool not found.  Install with:  $(install_hint "$tool")"
}

require_docker() {
    have docker || die "docker not found.  Install with:  $(install_hint docker.io)"
    if ! docker info >/dev/null 2>&1; then
        die "docker daemon not reachable.  Check 'docker info' (daemon running? user in 'docker' group?)"
    fi
}

# ─── buildx / binfmt setup ─────────────────────────────────────────────────
ensure_buildx() {
    require_docker
    docker buildx version >/dev/null 2>&1 \
        || die "docker buildx not available.  Install docker-buildx-plugin or upgrade docker."
}

ensure_buildx_multiarch_for() {
    # If building for a non-host arch, the host needs binfmt_misc registration.
    # The portable way for docker is to install/register tonistiigi/binfmt:
    #   docker run --privileged --rm tonistiigi/binfmt --install all
    # The script does NOT auto-run privileged containers — it tells the user.
    local arch="$1"
    [[ "$arch" == "$(detect_host_arch)" ]] && return 0
    local q
    case "$arch" in
        aarch64) q=aarch64 ;;
        armv7l)  q=arm     ;;
        ppc64le) q=ppc64le ;;
        riscv64) q=riscv64 ;;
        s390x)   q=s390x   ;;
        *) die "unknown arch for binfmt: $arch" ;;
    esac
    if [[ ! -e "/proc/sys/fs/binfmt_misc/qemu-${q}" ]] \
       || ! grep -q '^enabled' "/proc/sys/fs/binfmt_misc/qemu-${q}" 2>/dev/null; then
        die "binfmt qemu-${q} not registered.  Enable with one of:
        sudo apt-get install -y qemu-user-static binfmt-support
        sudo update-binfmts --enable qemu-${q}
   or, the docker-native way:
        docker run --privileged --rm tonistiigi/binfmt --install all"
    fi
}

ensure_buildx_builder() {
    # For multi-platform builds we need a builder with a non-'docker' driver.
    # If the user has none, create a dedicated 'lab-builder' on docker-container.
    local b
    b="$(docker buildx ls 2>/dev/null | awk '/docker-container/{print $1; exit}')"
    if [[ -n "$b" ]]; then
        log_debug "using existing buildx builder: $b"
        printf '%s' "$b"
        return 0
    fi
    log_info "creating buildx builder 'lab-builder' (driver=docker-container)"
    docker buildx create --name lab-builder --driver docker-container >/dev/null \
        || die "docker buildx create failed"
    docker buildx inspect --bootstrap lab-builder >/dev/null
    printf 'lab-builder'
}

# ─── TOML parser abstraction ────────────────────────────────────────────────
toml_to_json() {
    local file="$1"
    [[ -r "$file" ]] || die "config file not readable: $file"
    if have tomlq; then
        tomlq -c '.' "$file"
    elif have yq && yq --version 2>&1 | grep -qi 'mikefarah'; then
        yq -p toml -o json "$file"
    elif have dasel; then
        dasel -f "$file" -r toml -w json
    else
        die "no TOML parser found.  Install one of:
        $(install_hint yq)        # mikefarah/yq, supports -p toml
   or   pipx install yq           # kislyuk/yq → tomlq
   or   install dasel from https://github.com/tomwright/dasel"
    fi
}

# ─── Compose YAML → internal JSON (for --config *.yml / *.yaml) ───────────
# Converts a docker-compose v2 file to the same JSON schema that toml_to_json
# produces, so all downstream code is format-agnostic.
# Supported subset: services (image, ports, environment, volumes, networks,
# command, depends_on, healthcheck), top-level networks, and `name`.
# Volumes in object form {source, target} are not supported — use string form.
compose_to_json() {
    local file="$1"
    [[ -r "$file" ]] || die "config file not readable: $file"
    have yq && yq --version 2>&1 | grep -qi 'mikefarah' \
        || die "Compose YAML interop requires mikefarah/yq.  Install with:  $(install_hint yq)"
    yq -p yaml -o json "$file" | jq -c '
        . as $c |
        # Compose environment can be a {k:v} map or a ["K=V"] list; normalise
        # to a map so the rest of the code can use to_entries.
        def env_map(e):
          if (e | type) == "object" then e
          elif (e | type) == "array"  then
            (e | map(
              split("=") |
              {key: .[0], value: (.[1:] | join("="))}
            ) | from_entries)
          else {} end;
        # depends_on can be a ["svc"] list or a {svc: {condition:...}} map.
        def dep_list(d):
          if (d | type) == "array"  then d
          elif (d | type) == "object" then [d | keys[]]
          else [] end;
        # healthcheck.test: ["CMD-SHELL","cmd"] -> "cmd"; "none" -> ""
        def hc_test(t):
          if (t | type) == "array" then
            if t[0] == "CMD-SHELL" or t[0] == "CMD" then t[1:] | join(" ")
            else "" end
          elif (t | type) == "string" and t != "none" then t
          else "" end;
        {
          lab: { name: ($c.name // "") },
          network: (
            ($c.networks // {}) | to_entries |
            map({ key: .key,
                  value: { driver: (.value.driver // "bridge") } }) |
            from_entries
          ),
          service: [
            ($c.services // {}) | to_entries[] |
            .key as $n | .value as $s |
            {
              name:        $n,
              image:       ($s.image // ""),
              ports:       ($s.ports // []),
              environment: env_map($s.environment),
              volumes:     ($s.volumes // []),
              networks:    (
                if ($s.networks | type) == "object" then [$s.networks | keys[]]
                else ($s.networks // []) end
              ),
              command:     (if ($s.command | type) == "string" then $s.command else "" end),
              cmd:         (if ($s.command | type) == "array"  then $s.command else [] end),
              depends_on:  dep_list($s.depends_on),
              healthcheck: (
                if $s.healthcheck then {
                  test:         hc_test($s.healthcheck.test),
                  interval:     ($s.healthcheck.interval     // ""),
                  timeout:      ($s.healthcheck.timeout      // ""),
                  retries:      ($s.healthcheck.retries      // 0 | tostring),
                  start_period: ($s.healthcheck.start_period // "")
                } | with_entries(select(.value != "" and .value != "0"))
                else null end
              )
            } | with_entries(select(
                  .value != "" and .value != null and .value != [] and .value != {}
                ))
          ]
        }
    '
}

# Dispatch on file extension: .yml/.yaml → compose_to_json, else toml_to_json.
load_config() {
    local file="$1"
    case "$file" in
        *.yml|*.yaml) compose_to_json "$file" ;;
        *)            toml_to_json    "$file" ;;
    esac
}

# ─── Container/image naming helpers ────────────────────────────────────────
container_name_for() {
    # container_name_for LAB_NAME SERVICE_NAME
    printf 'lab-%s-%s' "$1" "$2"
}

# ─── Backend: from-chroot import ───────────────────────────────────────────
backend_from_chroot() {
    # backend_from_chroot CHROOT_PATH IMAGE_TAG
    local chroot_path="$1" image_tag="$2"
    [[ -d "$chroot_path" ]] || die "chroot not found: $chroot_path"
    require_cmd tar

    # Readability preflight: chroots built via `sudo lab-chroot create`
    # contain root-mode-600 files (/etc/shadow, /root/*, etc.) that an
    # unprivileged tar can't read.  The stream would complete with a
    # half-imported image and set -o pipefail would then trip, leaving
    # a garbage image ghost in `docker images`.  Detect and redirect the
    # user to the clean alternative: lab-chroot export-tarball +
    # from_tarball.
    local unreadable; unreadable="$(
        find "$chroot_path" -xdev \
            -not -path "${chroot_path}/proc/*" \
            -not -path "${chroot_path}/sys/*" \
            -not -path "${chroot_path}/dev/*" \
            -not -readable -print -quit 2>/dev/null
    )"
    if [[ -n "$unreadable" ]]; then
        die "chroot '$chroot_path' contains files unreadable by this user
  (first offender: $unreadable).  This usually means the chroot was built
  via 'sudo lab-chroot create', leaving mode-600 root-owned files inside.

  Rootless workaround (recommended):
    sudo phase1-chroot/lab-chroot.sh export-tarball <name> --output /tmp/<name>.tar.gz
  Then reference that file via --backend from-tarball / --tarball, or in
  a topology TOML via the service's from_tarball field.

  Or, for a quick-and-dirty manual prep:
    sudo tar -C $chroot_path -cpzf /tmp/chroot.tar.gz \\
        --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \\
        --exclude='./run/*'  --exclude='./tmp/*' .
    sudo chown \$(id -u):\$(id -g) /tmp/chroot.tar.gz"
    fi

    log_info "tar | docker import → $image_tag  (from $chroot_path)"
    if ! tar -C "$chroot_path" \
            --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
            --exclude='./run/*'  --exclude='./tmp/*' \
            --exclude='./.lab-chroot-mounts' \
            --numeric-owner -c . \
          | docker import - "$image_tag" >/dev/null; then
        docker rmi "$image_tag" >/dev/null 2>&1 || true
        die "from-chroot import failed; partial image removed."
    fi
    log_info "imported: $image_tag"
}

# ─── Backend: from-tarball import ──────────────────────────────────────────
# Rootless-clean alternative to from-chroot: accept a self-contained,
# user-readable tarball (e.g. produced by `lab-chroot export-tarball`)
# and `docker import` it directly.  Bypasses the tar-from-a-directory
# step so root-owned chroots can be imported without needing sudo.
backend_from_tarball() {
    # backend_from_tarball TARBALL_PATH IMAGE_TAG
    local tarball="$1" image_tag="$2"
    [[ -r "$tarball" ]] || die "tarball not readable: $tarball"
    log_info "docker import $tarball → $image_tag"
    if ! docker import "$tarball" "$image_tag" >/dev/null; then
        docker rmi "$image_tag" >/dev/null 2>&1 || true
        die "from-tarball import failed; partial image removed."
    fi
    log_info "imported: $image_tag"
}

# ─── Backend: buildx ───────────────────────────────────────────────────────
backend_buildx() {
    # backend_buildx CONTEXT_DIR IMAGE_TAG ARCH
    local context="$1" tag="$2" arch="$3"
    [[ -d "$context" ]] || die "build context not a directory: $context"
    [[ -r "$context/Dockerfile" ]] || die "no Dockerfile in $context"
    ensure_buildx
    ensure_buildx_multiarch_for "$arch"
    local platform; platform="$(docker_platform "$arch")"
    local builder
    if [[ "$arch" == "$(detect_host_arch)" ]]; then
        # Single-platform host build can use the default builder + --load.
        log_info "buildx build (host arch): $tag for $platform"
        docker buildx build --platform "$platform" --load -t "$tag" "$context"
    else
        builder="$(ensure_buildx_builder)"
        log_info "buildx build (foreign arch): $tag for $platform via $builder"
        docker buildx build --builder "$builder" --platform "$platform" --load \
            -t "$tag" "$context"
    fi
}

# ─── Spec construction ─────────────────────────────────────────────────────
# A "service spec" is a JSON object describing one container in a topology
# (or one ad-hoc container for `run`).
spec_get() { jq -r --arg k "$2" '.[$k] // ""' <<<"$1"; }

# ─── Topological sort for depends_on ordering ──────────────────────────────
# Globals used: _TOPO_VISITED (assoc array), _TOPO_SORTED (index array).
# Both are declared with declare -g by topo_sort() before calling _topo_visit.
_topo_visit() {
    local name="$1" svc_json="$2"
    local state="${_TOPO_VISITED[$name]:-}"
    [[ "$state" == "done"    ]] && return 0
    [[ "$state" == "pending" ]] && die "depends_on cycle detected at service '$name'"
    _TOPO_VISITED[$name]="pending"
    local dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        # Soft-check: warn if dep not in list (may be a cross-engine service).
        if ! jq -e --arg d "$dep" 'map(select(.name==$d)) | length > 0' \
               <<<"$svc_json" >/dev/null 2>&1; then
            log_warn "service '$name' depends_on '$dep' which is not in this topology"
        fi
        _topo_visit "$dep" "$svc_json"
    done < <(jq -r --arg n "$name" \
        '.[] | select(.name==$n) | .depends_on // [] | .[]?' <<<"$svc_json")
    _TOPO_VISITED[$name]="done"
    _TOPO_SORTED+=("$name")
}

# topo_sort SVC_JSON_ARRAY — sets _TOPO_SORTED to names in dependency-first order.
topo_sort() {
    local svc_json="$1"
    declare -gA _TOPO_VISITED=()
    declare -ga _TOPO_SORTED=()
    local count; count="$(jq 'length' <<<"$svc_json")"
    local i name
    for ((i=0; i<count; i++)); do
        name="$(jq -r --argjson i "$i" '.[$i].name // ""' <<<"$svc_json")"
        [[ -n "$name" ]] && _topo_visit "$name" "$svc_json"
    done
}

# ─── Health-wait helper for depends_on with healthchecks ───────────────────
_wait_healthy() {
    local cname="$1"
    local max_wait="${2:-120}" elapsed=0
    log_info "waiting for '$cname' to become healthy (max ${max_wait}s)…"
    while (( elapsed < max_wait )); do
        local h
        h="$(docker inspect --format '{{.State.Health.Status}}' "$cname" 2>/dev/null || true)"
        case "$h" in
            healthy)   log_debug "'$cname' is healthy"; return 0 ;;
            unhealthy) die "container '$cname' is unhealthy" ;;
        esac
        sleep 2; elapsed=$((elapsed+2))
    done
    die "timed out waiting for '$cname' to become healthy (${max_wait}s)"
}

# ─── Subcommand: build ─────────────────────────────────────────────────────
cmd_build() {
    local backend="${OPT_BACKEND:-build}"
    local tag="${OPT_TAG:-}"
    [[ -n "$tag" ]] || die "usage: $LAB_PROG build --tag NAME [--backend buildx|from-chroot|from-tarball] ..."
    local arch="${OPT_ARCH:-$(detect_host_arch)}"
    is_known_arch "$arch" || die "unknown arch: $arch"
    case "$backend" in
        buildx|build|from-chroot|from-tarball) ;;
        *) die "unknown build backend: $backend" ;;
    esac
    if [[ "$backend" == "from-chroot" ]]; then
        [[ -n "${OPT_CHROOT:-}" ]] || die "--backend from-chroot requires --chroot PATH"
    fi
    if [[ "$backend" == "from-tarball" ]]; then
        [[ -n "${OPT_TARBALL:-}" ]] || die "--backend from-tarball requires --tarball FILE"
    fi

    require_docker

    case "$backend" in
        buildx|build)
            local context="${OPT_CONTEXT:-.}"
            backend_buildx "$context" "$tag" "$arch"
            ;;
        from-chroot)
            backend_from_chroot "$OPT_CHROOT" "$tag"
            ;;
        from-tarball)
            backend_from_tarball "$OPT_TARBALL" "$tag"
            ;;
    esac
}

# ─── Subcommand: push ──────────────────────────────────────────────────────
cmd_push() {
    local tag="${OPT_TAG:-${POS_ARGS[0]:-}}"
    [[ -n "$tag" ]] || die "usage: $LAB_PROG push <tag> | --tag TAG"
    require_docker
    if [[ -n "${OPT_ARCH:-}" ]]; then
        log_warn "push: --arch specified; pushing single-platform image '$tag'."
        log_warn "  Multi-arch manifest lists require: docker manifest push (after docker manifest create)"
    fi
    log_info "docker push $tag"
    docker push "$tag"
}

# ─── Subcommand: run (ad-hoc single container) ─────────────────────────────
cmd_run() {
    local image="${OPT_IMAGE:-}"
    local name="${OPT_NAME:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG run --name N --image IMG [opts...]"
    if [[ -z "$image" && -z "${OPT_CHROOT:-}" && -z "${OPT_TARBALL:-}" && -z "${OPT_CONTEXT:-}" ]]; then
        die "need one of: --image IMG | --chroot PATH | --tarball FILE | --context DIR"
    fi

    require_docker

    # Optional implicit build/import paths.
    if [[ -z "$image" ]]; then
        if [[ -n "${OPT_TARBALL:-}" ]]; then
            image="lab-from-tarball-${name}"
            backend_from_tarball "$OPT_TARBALL" "$image"
        elif [[ -n "${OPT_CHROOT:-}" ]]; then
            image="lab-from-chroot-${name}"
            backend_from_chroot "$OPT_CHROOT" "$image"
        elif [[ -n "${OPT_CONTEXT:-}" ]]; then
            image="lab-build-${name}"
            backend_buildx "$OPT_CONTEXT" "$image" "${OPT_ARCH:-$(detect_host_arch)}"
        fi
    fi

    local cname; cname="lab-${name}"

    # Detect existing container with the same name and refuse (idempotency).
    if docker ps -a --format '{{.Names}}' | grep -qx "$cname"; then
        die "container '$cname' already exists.  Destroy it first:  $LAB_PROG destroy $name"
    fi

    local -a args=(
        --label "$LAB_LABEL_TOOL"
        --label "${LAB_LABEL_LAB}=adhoc"
        --label "${LAB_LABEL_SVC}=${name}"
        --name "$cname"
    )

    [[ -n "${OPT_ARCH:-}" ]] && args+=(--platform "$(docker_platform "$OPT_ARCH")")
    [[ -n "${OPT_NETWORK:-}" ]] && args+=(--network "$OPT_NETWORK")
    [[ -n "${OPT_HOSTNAME:-}" ]] && args+=(--hostname "$OPT_HOSTNAME")

    local p
    if [[ -n "${OPT_PORTS:-}" ]]; then
        IFS=',' read -ra _ports <<<"$OPT_PORTS"
        for p in "${_ports[@]}"; do args+=(-p "$p"); done
    fi
    local e
    if [[ -n "${OPT_ENV:-}" ]]; then
        IFS=',' read -ra _envs <<<"$OPT_ENV"
        for e in "${_envs[@]}"; do args+=(-e "$e"); done
    fi
    local v
    if [[ -n "${OPT_VOLUMES:-}" ]]; then
        IFS=',' read -ra _vols <<<"$OPT_VOLUMES"
        for v in "${_vols[@]}"; do args+=(-v "$v"); done
    fi

    if [[ -n "${OPT_DETACH:-}" ]]; then
        args+=(-d)
    fi
    if [[ -n "${OPT_RM:-}" ]]; then
        args+=(--rm)
    fi
    if [[ -n "${OPT_TTY:-}" ]]; then
        args+=(-i)
        [[ -t 0 ]] && args+=(-t)
    fi

    log_info "docker run $cname (image=$image)"
    log_debug "argv: docker run ${args[*]} $image ${EXTRA_ARGS[*]:-}"
    if (( ${#EXTRA_ARGS[@]} > 0 )); then
        docker run "${args[@]}" "$image" "${EXTRA_ARGS[@]}"
    else
        docker run "${args[@]}" "$image"
    fi
}

# ─── Subcommand: up (topology) ─────────────────────────────────────────────
cmd_up() {
    [[ -n "${OPT_CONFIG:-}" ]] || die "usage: $LAB_PROG up --config topology.toml"
    require_cmd jq
    require_docker
    local cfg_json; cfg_json="$(load_config "$OPT_CONFIG")"

    local lab_name
    lab_name="$(jq -r '.lab.name // ""' <<<"$cfg_json")"
    [[ -n "$lab_name" ]] || die "config missing [lab].name"

    log_info "── bringing up lab '$lab_name' from $OPT_CONFIG ──"

    # If we exit with a partial topology, hint at the cleanup command. Embed
    # the literal lab name into the trap string at trap-set time (function-
    # scoped traps fire at script-exit, by which point the local is gone;
    # under `set -u` that turns into "$var: unbound variable" instead of the
    # intended log line). The actual teardown is label-based and idempotent,
    # so we only need to point the user at it.
    trap "log_warn \"partial 'up' for lab '${lab_name}' — clean up with:  ${LAB_PROG} down --lab ${lab_name}\"" EXIT

    # --- Networks ---
    local nets
    nets="$(jq -r '.network // {} | keys[]?' <<<"$cfg_json")"
    local net
    for net in $nets; do
        local driver; driver="$(jq -r --arg n "$net" '.network[$n].driver // "bridge"' <<<"$cfg_json")"
        local netname; netname="lab-${lab_name}-${net}"
        if docker network ls --format '{{.Name}}' | grep -qx "$netname"; then
            log_debug "network exists: $netname"
        else
            log_info "creating network: $netname (driver=$driver)"
            docker network create \
                --label "$LAB_LABEL_TOOL" \
                --label "${LAB_LABEL_LAB}=${lab_name}" \
                --driver "$driver" \
                "$netname" >/dev/null
        fi
    done

    # --- Services ---
    local svc_count; svc_count="$(jq -r '.service // [] | length' <<<"$cfg_json")"
    [[ "$svc_count" -gt 0 ]] || die "config has no [[service]] entries"

    # Build a compact JSON array of all service objects, then topologically
    # sort them so that services listed in depends_on start before their
    # dependents.  The sort uses all services (including cross-engine ones) so
    # that depends_on references to podman-managed siblings don't cause errors.
    local all_svcs; all_svcs="$(jq -c '.service // []' <<<"$cfg_json")"
    topo_sort "$all_svcs"
    local -a ordered_names=("${_TOPO_SORTED[@]}")

    local skipped=0 started=0
    local sname
    for sname in "${ordered_names[@]}"; do
        local svc; svc="$(jq -c --arg n "$sname" '.[] | select(.name==$n)' <<<"$all_svcs")"
        local simage; simage="$(spec_get "$svc" image)"

        # Cross-phase engine routing.
        local sengine; sengine="$(spec_get "$svc" engine)"
        if [[ -n "$sengine" && "$sengine" != "docker" ]]; then
            log_debug "skipping service '$sname' (engine=$sengine, not docker)"
            skipped=$((skipped+1))
            continue
        fi

        local cname; cname="$(container_name_for "$lab_name" "$sname")"

        # Idempotency: if a container of this name exists already, leave it.
        if docker ps -a --format '{{.Names}}' | grep -qx "$cname"; then
            log_warn "service '$sname' container exists ($cname); leaving as-is"
            started=$((started+1))
            continue
        fi

        # Image source: explicit image | from_tarball | from_chroot | build
        if [[ -z "$simage" ]]; then
            local tarball; tarball="$(spec_get "$svc" from_tarball)"
            local chroot;  chroot="$(spec_get "$svc" from_chroot)"
            local ctx;     ctx="$(spec_get "$svc" build)"
            if [[ -n "$tarball" && -n "$chroot" ]]; then
                die "service '$sname': from_tarball and from_chroot are mutually exclusive — pick one"
            fi
            if [[ -n "$tarball" ]]; then
                simage="lab-${lab_name}-${sname}-img"
                backend_from_tarball "$tarball" "$simage"
            elif [[ -n "$chroot" ]]; then
                simage="lab-${lab_name}-${sname}-img"
                backend_from_chroot "$chroot" "$simage"
            elif [[ -n "$ctx" ]]; then
                simage="lab-${lab_name}-${sname}-img"
                backend_buildx "$ctx" "$simage" "${OPT_ARCH:-$(detect_host_arch)}"
            else
                die "service '$sname': specify one of image | from_tarball | from_chroot | build"
            fi
        fi

        local -a args=(
            --detach
            --label "$LAB_LABEL_TOOL"
            --label "${LAB_LABEL_LAB}=${lab_name}"
            --label "${LAB_LABEL_SVC}=${sname}"
            --name "$cname"
            --hostname "$sname"
        )

        # Networks
        local svc_nets; svc_nets="$(jq -r '.networks[]?' <<<"$svc")"
        local first_net=""
        local n
        for n in $svc_nets; do
            local nn="lab-${lab_name}-${n}"
            if [[ -z "$first_net" ]]; then
                args+=(--network "$nn")
                first_net="$nn"
            else
                # Additional networks attached after start.
                :
            fi
        done

        # Ports
        local pp
        while IFS= read -r pp; do
            [[ -n "$pp" ]] && args+=(-p "$pp")
        done < <(jq -r '.ports[]?' <<<"$svc")

        # Env
        local kk vv
        while IFS=$'\t' read -r kk vv; do
            [[ -n "$kk" ]] && args+=(-e "${kk}=${vv}")
        done < <(jq -r '.environment // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$svc")

        # Volumes
        local vv2
        while IFS= read -r vv2; do
            [[ -n "$vv2" ]] && args+=(-v "$vv2")
        done < <(jq -r '.volumes[]?' <<<"$svc")

        # Healthcheck — translates TOML [service.healthcheck] to docker run flags.
        local hc_test hc_interval hc_timeout hc_retries hc_start
        hc_test="$(    jq -r '.healthcheck.test         // ""' <<<"$svc")"
        hc_interval="$(jq -r '.healthcheck.interval     // ""' <<<"$svc")"
        hc_timeout="$( jq -r '.healthcheck.timeout      // ""' <<<"$svc")"
        hc_retries="$( jq -r '.healthcheck.retries      // ""' <<<"$svc")"
        hc_start="$(   jq -r '.healthcheck.start_period // ""' <<<"$svc")"
        if [[ -n "$hc_test" ]]; then
            args+=(--health-cmd "$hc_test")
            [[ -n "$hc_interval" ]] && args+=(--health-interval "$hc_interval")
            [[ -n "$hc_timeout"  ]] && args+=(--health-timeout  "$hc_timeout")
            [[ -n "$hc_retries"  ]] && args+=(--health-retries  "$hc_retries")
            [[ -n "$hc_start"    ]] && args+=(--health-start-period "$hc_start")
        fi

        # Optional command after image
        local -a cmd=()
        local cmdline; cmdline="$(jq -r '.command // empty' <<<"$svc")"
        if [[ -n "$cmdline" ]]; then
            # naive split — TOML users wanting complex cmdlines should pre-split as array
            read -ra cmd <<<"$cmdline"
        else
            local cmdcount; cmdcount="$(jq -r '.cmd // [] | length' <<<"$svc")"
            if (( cmdcount > 0 )); then
                local k
                for ((k=0; k<cmdcount; k++)); do
                    cmd+=("$(jq -r --argjson k "$k" '.cmd[$k]' <<<"$svc")")
                done
            fi
        fi

        log_info "starting service '$sname' as $cname (image=$simage)"
        docker run "${args[@]}" "$simage" "${cmd[@]}" >/dev/null
        started=$((started+1))

        # Attach extra networks (if user listed >1)
        local idx=0
        for n in $svc_nets; do
            local nn="lab-${lab_name}-${n}"
            (( idx > 0 )) && docker network connect "$nn" "$cname" >/dev/null
            idx=$((idx+1))
        done

        # If this service has a healthcheck, wait for it before continuing —
        # its dependents (which are next in the sorted order) may need it healthy.
        if [[ -n "$hc_test" ]]; then
            _wait_healthy "$cname"
        fi
    done

    # Success — clear the partial-up hint trap.
    trap - EXIT

    log_info "── lab '$lab_name' up (${started} docker service(s), ${skipped} skipped) ──"
    log_info "list:  $LAB_PROG list --lab $lab_name"
    log_info "down:  $LAB_PROG down --lab $lab_name"
}

# ─── Subcommand: down ──────────────────────────────────────────────────────
cmd_down() {
    local lab_name="${OPT_LAB:-}"
    if [[ -z "$lab_name" && -n "${OPT_CONFIG:-}" ]]; then
        require_cmd jq
        lab_name="$(load_config "$OPT_CONFIG" | jq -r '.lab.name // ""')"
    fi
    [[ -n "$lab_name" ]] || die "usage: $LAB_PROG down --lab NAME | --config topology.toml (need a lab name)"
    require_docker

    log_info "── tearing down lab '$lab_name' ──"

    # Containers first.
    local ids
    ids="$(docker ps -aq --filter "label=${LAB_LABEL_LAB}=${lab_name}" --filter "label=${LAB_LABEL_TOOL}")"
    if [[ -n "$ids" ]]; then
        log_info "stopping/removing $(wc -w <<<"$ids") container(s)"
        # shellcheck disable=SC2086
        docker rm -f $ids >/dev/null 2>&1 \
            || { docker stop $ids >/dev/null 2>&1 || true
                 # shellcheck disable=SC2086
                 docker rm   $ids >/dev/null 2>&1 || true; }
    fi

    # Then networks.
    local nids
    nids="$(docker network ls -q --filter "label=${LAB_LABEL_LAB}=${lab_name}" --filter "label=${LAB_LABEL_TOOL}")"
    if [[ -n "$nids" ]]; then
        log_info "removing $(wc -w <<<"$nids") network(s)"
        # shellcheck disable=SC2086
        docker network rm $nids >/dev/null 2>&1 || true
    fi

    log_info "── lab '$lab_name' torn down ──"
}

# ─── Subcommand: exec ──────────────────────────────────────────────────────
cmd_exec() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG exec <name|lab/service> [-- cmd args...]"
    require_docker
    local cname; cname="$(_resolve_container_name "$target")"
    local -a tty_flag=(); [[ -t 0 ]] && tty_flag=(-t)
    if (( ${#EXTRA_ARGS[@]} > 0 )); then
        docker exec -i "${tty_flag[@]}" "$cname" "${EXTRA_ARGS[@]}"
    else
        docker exec -i "${tty_flag[@]}" "$cname" /bin/sh -c '[ -x /bin/bash ] && exec /bin/bash || exec /bin/sh'
    fi
}

# ─── Subcommand: logs ──────────────────────────────────────────────────────
cmd_logs() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG logs <name|lab/service> [--follow]"
    require_docker
    local cname; cname="$(_resolve_container_name "$target")"
    if [[ -n "${OPT_FOLLOW:-}" ]]; then
        docker logs -f "$cname"
    else
        docker logs --tail 100 "$cname"
    fi
}

# Helper: resolve "name" (ad-hoc) or "lab/service" → container name.
_resolve_container_name() {
    local t="$1"
    if [[ "$t" == */* ]]; then
        local lab="${t%%/*}" svc="${t##*/}"
        printf 'lab-%s-%s' "$lab" "$svc"
    else
        printf 'lab-%s' "$t"
    fi
}

# ─── Subcommand: list ──────────────────────────────────────────────────────
cmd_list() {
    # Suppress SIGPIPE for this function: callers often pipe our output through
    # `grep -q`, which exits on the first match and closes the read end of the
    # pipe.  External commands then get SIGPIPE (exit 141) which `|| true`
    # handles, but bash builtins (printf) run *in the shell process* — the
    # shell itself receives SIGPIPE and exits before `|| true` can fire.
    # `trap '' PIPE` makes the kernel convert SIGPIPE to EPIPE errno instead,
    # so builtins return 1 (not die) and `|| true` can catch them.
    trap '' PIPE
    require_docker
    if [[ -n "${OPT_LAB:-}" ]]; then
        printf '── lab: %s ──\n' "$OPT_LAB" || true
        docker ps -a --filter "label=${LAB_LABEL_LAB}=${OPT_LAB}" --filter "label=${LAB_LABEL_TOOL}" \
            --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true
        printf '\n[networks]\n' || true
        docker network ls --filter "label=${LAB_LABEL_LAB}=${OPT_LAB}" --filter "label=${LAB_LABEL_TOOL}" \
            --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}' || true
        return 0
    fi
    printf '── all labs (lab-create-managed only) ──\n' || true
    docker ps -a --filter "label=${LAB_LABEL_TOOL}" \
        --format 'table {{.Label "lab-create.lab"}}\t{{.Label "lab-create.svc"}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' || true
    printf '\n[networks]\n' || true
    docker network ls --filter "label=${LAB_LABEL_TOOL}" \
        --format 'table {{.Label "lab-create.lab"}}\t{{.Name}}\t{{.Driver}}' || true
}

# ─── Subcommand: destroy ───────────────────────────────────────────────────
cmd_destroy() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG destroy <name|lab/service> [--force]"
    require_docker

    if [[ -z "${OPT_FORCE:-}" ]]; then
        printf 'About to destroy: %s\nProceed? [y/N] ' "$target" >&2
        read -r ans </dev/tty || true
        case "$ans" in y|Y|yes|YES) ;; *) die "aborted" ;; esac
    fi

    local cname; cname="$(_resolve_container_name "$target")"
    if docker ps -a --format '{{.Names}}' | grep -qx "$cname"; then
        log_info "removing $cname"
        # docker rm -f handles both running and stopped containers;
        # fall back to stop+rm for daemons that reject SIGKILL via rm -f.
        docker rm -f "$cname" >/dev/null 2>&1 \
            || { docker stop "$cname" >/dev/null 2>&1 || true
                 docker rm   "$cname" >/dev/null 2>&1 || true; }
    else
        die "no container named $cname"
    fi
    log_info "destroyed: $cname"
}

# ─── Subcommand: status ────────────────────────────────────────────────────
# Three call shapes (mirrors lab-podman.sh status):
#   status                        → daemon/host summary
#   status <lab>                  → every container + network tagged lab=<lab>
#   status <name>  |  <lab>/<svc> → single-container detail
#
# The <lab> vs <name> discriminator: if a container named `lab-<arg>` exists,
# treat <arg> as a container name; otherwise look for labeled children and,
# if any exist, treat <arg> as a lab name.
cmd_status() {
    local target="${POS_ARGS[0]:-${OPT_LAB:-}}"
    require_docker

    if [[ -z "$target" ]]; then
        printf '── docker info (summary) ──\n'
        # Trailing `|| true` is deliberate: if the consumer is a pager or
        # `grep -q` that closes early, SIGPIPE propagates through
        # `set -o pipefail` and makes `status` look like it failed.
        { docker info --format '{{"host:          "}}{{.Name}}
{{"server ver:   "}}{{.ServerVersion}}
{{"arch:         "}}{{.Architecture}}
{{"os:           "}}{{.OperatingSystem}}
{{"driver:       "}}{{.Driver}}
{{"storage root: "}}{{.DockerRootDir}}
{{"containers:   "}}{{.Containers}} ({{.ContainersRunning}} running)' 2>/dev/null \
            || docker info; } || true
        return 0
    fi

    # Lab-scoped branch: does any container carry label=<target>?
    local lab_hits
    lab_hits="$(docker ps -aq \
        --filter "label=${LAB_LABEL_LAB}=${target}" \
        --filter "label=${LAB_LABEL_TOOL}" 2>/dev/null)"
    local net_hits
    net_hits="$(docker network ls -q \
        --filter "label=${LAB_LABEL_LAB}=${target}" \
        --filter "label=${LAB_LABEL_TOOL}" 2>/dev/null)"

    # Container-scoped: does a container of this name (possibly `lab-<arg>`) exist?
    local cname; cname="$(_resolve_container_name "$target")"
    local container_hit=0
    docker ps -a --format '{{.Names}}' | grep -qx "$cname" && container_hit=1

    if [[ -n "$lab_hits" || -n "$net_hits" ]] && (( ! container_hit )); then
        printf '── lab: %s ──\n' "$target"
        printf '\n[containers]\n'
        docker ps -a --filter "label=${LAB_LABEL_LAB}=${target}" --filter "label=${LAB_LABEL_TOOL}" \
            --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}' 2>/dev/null || true
        printf '\n[networks]\n'
        docker network ls --filter "label=${LAB_LABEL_LAB}=${target}" --filter "label=${LAB_LABEL_TOOL}" \
            --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}' 2>/dev/null || true
        return 0
    fi

    if (( container_hit )); then
        docker ps -a --filter "name=^${cname}$" \
            --format 'Name:    {{.Names}}
Image:   {{.Image}}
Status:  {{.Status}}
Ports:   {{.Ports}}
Created: {{.CreatedAt}}
Command: {{.Command}}
Lab:     {{.Label "lab-create.lab"}}
Service: {{.Label "lab-create.svc"}}'
        return 0
    fi

    die "no lab or container matches '$target' (tried container name '$cname' and label $LAB_LABEL_LAB=$target)"
}

# ─── Subcommand: export ────────────────────────────────────────────────────
# Emit a compose-format YAML that recreates the lab defined in --config.
# Phase 3 deliberately keeps no on-disk spec copy (label-first design), so
# unlike Phase 4's `export`, this one requires --config FILE — the TOML is
# the source of truth. Output goes to stdout so the caller can redirect.
#
# Coverage (v0.1, matches the fields lab-docker up actually honors):
#   services — image, ports, environment, volumes, networks, command
#   networks — per-topology [network.X] blocks, driver preserved
# ─── Subcommand: inspect ────────────────────────────────────────────────────
# Single-container detail report — folds `docker inspect`'s nested JSON
# into a stable schema_version=1 surface that the Phase 6 TUI can rely on.
#
# Two output modes:
#   default      → human-readable [labels] / [container] / [state] /
#                  [network] / [mounts] sections
#   --json       → one JSON document on stdout, schema_version=1
#
# Designed primarily as a machine-readable surface for Phase 6 (the TUI's
# docker detail panel).  CLI users get the same data but rendered.
#
# Name resolution mirrors cmd_exec / cmd_logs but tries the literal name
# first — so the TUI can pass `lab-demo-web` (already the on-engine name)
# AND humans can pass the short `demo/web` form.
cmd_inspect() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG inspect <name|lab/svc> [--json]"
    require_docker
    require_cmd jq

    # Try the literal name first; fall back to the lab-<...> rewrite.
    # `_resolve_container_name` always synthesizes `lab-<arg>` for a
    # single-token input, so passing `lab-demo-web` would otherwise become
    # `lab-lab-demo-web`.  Trying literal first lets both forms work.
    local cname=""
    if docker inspect "$target" >/dev/null 2>&1; then
        cname="$target"
    else
        cname="$(_resolve_container_name "$target")"
        docker inspect "$cname" >/dev/null 2>&1 \
            || die "no container matches '$target' (tried '$cname')"
    fi

    # `docker inspect` emits a JSON ARRAY with one entry; jq does the
    # schema flattening.  Doing this in jq (rather than printf-with-fields
    # like Phases 1/2) is much cleaner because docker's structure is
    # already well-typed.
    local rendered
    rendered="$(docker inspect "$cname" 2>/dev/null | jq -r '
        .[0] as $c |
        ($c.Config.Labels // {}) as $L |
        {
            schema_version: 1,
            name: ($c.Name | sub("^/"; "")),
            labels: {
                lab:    $L["lab-create.lab"],
                svc:    $L["lab-create.svc"],
                tool:   $L["lab-create.tool"],
                _other: ($L | with_entries(select(.key | startswith("lab-create.") | not)))
            },
            container: {
                id:         $c.Id,
                image:      $c.Config.Image,
                image_id:   $c.Image,
                command:    ($c.Config.Cmd // []),
                created_at: $c.Created
            },
            state: {
                status:        $c.State.Status,
                running:       $c.State.Running,
                started_at:    $c.State.StartedAt,
                finished_at:   ($c.State.FinishedAt // null),
                exit_code:     (if $c.State.Running then null else ($c.State.ExitCode // 0) end),
                restart_count: ($c.RestartCount // 0),
                pid:           (if ($c.State.Pid // 0) > 0 then $c.State.Pid else null end),
                health:        ($c.State.Health.Status // null)
            },
            network: {
                ports: [
                    ($c.NetworkSettings.Ports // {}) | to_entries[]
                    | .key as $port_proto
                    | ($port_proto | split("/")) as $pp
                    | (.value // [])[]?
                    | { container_port: ($pp[0] | tonumber),
                        protocol:       $pp[1],
                        host_ip:        .HostIp,
                        host_port:      (.HostPort | tonumber) }
                ],
                networks: [($c.NetworkSettings.Networks // {}) | keys[]?],
                ip_addresses: (
                    ($c.NetworkSettings.Networks // {})
                    | with_entries(.value = (.value.IPAddress // null))
                )
            },
            mounts: [
                ($c.Mounts // [])[] |
                { source:      .Source,
                  destination: .Destination,
                  type:        .Type,
                  readonly:    ((.RW // true) | not) }
            ]
        }
    ')"

    if [[ -n "${OPT_JSON:-}" ]]; then
        printf '%s\n' "$rendered"
        return 0
    fi

    # Human-readable rendering — derived from the JSON for consistency.
    printf '[labels]\n'
    printf '  lab            %s\n' "$(jq -r '.labels.lab  // "(none)"' <<<"$rendered")"
    printf '  svc            %s\n' "$(jq -r '.labels.svc  // "(none)"' <<<"$rendered")"
    printf '  tool           %s\n' "$(jq -r '.labels.tool // "(none)"' <<<"$rendered")"

    printf '\n[container]\n'
    printf '  name           %s\n' "$cname"
    printf '  id             %s\n' "$(jq -r '.container.id[0:12]' <<<"$rendered")"
    printf '  image          %s\n' "$(jq -r '.container.image' <<<"$rendered")"
    printf '  created_at     %s\n' "$(jq -r '.container.created_at' <<<"$rendered")"

    printf '\n[state]\n'
    printf '  status         %s\n' "$(jq -r '.state.status' <<<"$rendered")"
    printf '  running        %s\n' "$(jq -r '.state.running' <<<"$rendered")"
    printf '  started_at     %s\n' "$(jq -r '.state.started_at' <<<"$rendered")"
    printf '  finished_at    %s\n' "$(jq -r '.state.finished_at // "—"' <<<"$rendered")"
    printf '  exit_code      %s\n' "$(jq -r '.state.exit_code   // "—"' <<<"$rendered")"
    printf '  restart_count  %s\n' "$(jq -r '.state.restart_count' <<<"$rendered")"
    printf '  pid            %s\n' "$(jq -r '.state.pid    // "—"' <<<"$rendered")"
    printf '  health         %s\n' "$(jq -r '.state.health // "—"' <<<"$rendered")"

    printf '\n[network]\n'
    local nets; nets="$(jq -r '.network.networks | join(", ")' <<<"$rendered")"
    [[ -n "$nets" ]] && printf '  networks       %s\n' "$nets"
    while IFS=$'\t' read -r net ip; do
        [[ -z "$net" ]] && continue
        printf '  ip[%s]        %s\n' "$net" "${ip:-—}"
    done < <(jq -r '.network.ip_addresses | to_entries[]? | "\(.key)\t\(.value // "—")"' <<<"$rendered")
    while IFS=$'\t' read -r cport proto hip hport; do
        [[ -z "$cport" ]] && continue
        printf '  port           %s/%s → %s:%s\n' "$cport" "$proto" "${hip:-0.0.0.0}" "$hport"
    done < <(jq -r '.network.ports[]? | "\(.container_port)\t\(.protocol)\t\(.host_ip // "")\t\(.host_port)"' <<<"$rendered")

    if jq -e '.mounts | length > 0' <<<"$rendered" >/dev/null; then
        printf '\n[mounts]\n'
        local src dst type ro tag
        while IFS=$'\t' read -r src dst type ro; do
            [[ -z "$src" ]] && continue
            tag=""; [[ "$ro" == "true" ]] && tag=", ro"
            printf '  %s → %s (%s%s)\n' "$src" "$dst" "$type" "$tag"
        done < <(jq -r '.mounts[] | "\(.source)\t\(.destination)\t\(.type)\t\(.readonly)"' <<<"$rendered")
    fi
}

# Not emitted: restart, secrets (not in the Phase 3 TOML schema).
# healthcheck and depends_on are now emitted.
# `from_chroot` / `from_tarball` / `build` image sources
# don't round-trip — compose's `build:` key needs a Dockerfile context path,
# which Phase 3's TOML doesn't carry; those services are emitted with the
# image tag that `up` would synthesize (`lab-<lab>-<svc>-img`), plus a
# commented hint so the reader knows it won't build standalone.
cmd_export() {
    [[ -n "${OPT_CONFIG:-}" ]] || die "usage: $LAB_PROG export --config topology.toml [--format compose]"
    local fmt="${OPT_FORMAT:-compose}"
    [[ "$fmt" == "compose" ]] || die "unknown export format: $fmt (phase 3 supports: compose)"
    require_cmd jq

    local cfg; cfg="$(load_config "$OPT_CONFIG")"
    local lab; lab="$(jq -r '.lab.name // ""' <<<"$cfg")"
    [[ -n "$lab" ]] || die "config missing [lab].name"

    # If a POS_ARG was supplied, require it to match [lab].name.  Catches the
    # "exported the wrong lab" class of mistake cheaply.
    local requested="${POS_ARGS[0]:-}"
    if [[ -n "$requested" && "$requested" != "$lab" ]]; then
        die "--config declares [lab].name='$lab' but positional arg is '$requested'"
    fi

    # Compact array of all service objects — used for healthcheck lookups in
    # depends_on condition resolution.
    local all_svcs_x; all_svcs_x="$(jq -c '.service // []' <<<"$cfg")"

    # No top-level `version:` key — Compose v2 treats it as obsolete and warns.
    printf '# generated by %s export from %s\n' "$LAB_PROG" "$OPT_CONFIG"
    printf '# lab: %s\n' "$lab"
    printf 'services:\n'

    # Pass 1: collect every non-path volume source so we can declare them at
    # the top level (compose rejects services referring to undeclared named
    # volumes).  Anything whose source starts with `/`, `./`, or `../` is a
    # bind mount; everything else is a named volume.
    local -A named_volumes=()

    local svc_count; svc_count="$(jq -r '.service // [] | length' <<<"$cfg")"
    local i svc sname simage engine tarball chroot ctx
    for ((i=0; i<svc_count; i++)); do
        svc="$(jq -c --argjson i "$i" '.service[$i]' <<<"$cfg")"
        sname="$(spec_get "$svc" name)"
        [[ -n "$sname" ]] || die "service[$i] missing name"

        engine="$(spec_get "$svc" engine)"
        if [[ -n "$engine" && "$engine" != "docker" ]]; then
            log_debug "export: skipping service '$sname' (engine=$engine, not docker)"
            continue
        fi

        simage="$(spec_get "$svc" image)"
        tarball="$(spec_get "$svc" from_tarball)"
        chroot="$(spec_get "$svc" from_chroot)"
        ctx="$(spec_get "$svc" build)"

        printf '  %s:\n' "$sname"
        printf '    container_name: lab-%s-%s\n' "$lab" "$sname"
        if [[ -n "$simage" ]]; then
            printf '    image: %s\n' "$simage"
        elif [[ -n "$tarball" ]]; then
            printf '    image: lab-%s-%s-img   # source: from_tarball=%s (not rebuildable via compose)\n' "$lab" "$sname" "$tarball"
        elif [[ -n "$chroot" ]]; then
            printf '    image: lab-%s-%s-img   # source: from_chroot=%s (not rebuildable via compose)\n' "$lab" "$sname" "$chroot"
        elif [[ -n "$ctx" ]]; then
            printf '    build: %s\n' "$ctx"
        else
            printf '    image: scratch   # WARNING: service had no image source in the TOML\n'
        fi
        printf '    hostname: %s\n' "$sname"

        local p first
        first=1
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            if (( first )); then printf '    ports:\n'; first=0; fi
            printf '      - "%s"\n' "$p"
        done < <(jq -r '.ports[]?' <<<"$svc")

        first=1
        local kk vv
        while IFS=$'\t' read -r kk vv; do
            [[ -z "$kk" ]] && continue
            if (( first )); then printf '    environment:\n'; first=0; fi
            printf '      %s: "%s"\n' "$kk" "$vv"
        done < <(jq -r '.environment // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$svc")

        first=1
        local vol vol_src
        while IFS= read -r vol; do
            [[ -z "$vol" ]] && continue
            if (( first )); then printf '    volumes:\n'; first=0; fi
            printf '      - "%s"\n' "$vol"
            vol_src="${vol%%:*}"
            case "$vol_src" in
                /*|./*|../*) : ;;                           # bind mount
                *)           named_volumes["$vol_src"]=1 ;;  # named volume
            esac
        done < <(jq -r '.volumes[]?' <<<"$svc")

        first=1
        local svc_net
        while IFS= read -r svc_net; do
            [[ -z "$svc_net" ]] && continue
            if (( first )); then printf '    networks:\n'; first=0; fi
            printf '      - %s\n' "$svc_net"
        done < <(jq -r '.networks[]?' <<<"$svc")

        local cmdline; cmdline="$(jq -r '.command // empty' <<<"$svc")"
        if [[ -n "$cmdline" ]]; then
            printf '    command: %s\n' "$cmdline"
        else
            local cmdcount; cmdcount="$(jq -r '.cmd // [] | length' <<<"$svc")"
            if (( cmdcount > 0 )); then
                printf '    command:\n'
                local k part
                for ((k=0; k<cmdcount; k++)); do
                    part="$(jq -r --argjson k "$k" '.cmd[$k]' <<<"$svc")"
                    printf '      - "%s"\n' "$part"
                done
            fi
        fi

        # depends_on — emit with condition based on whether the dependency has
        # a healthcheck (service_healthy) or not (service_started).
        first=1
        local dep dep_hc
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            if (( first )); then printf '    depends_on:\n'; first=0; fi
            dep_hc="$(jq -r --arg d "$dep" \
                '.[] | select(.name==$d) | .healthcheck.test // ""' \
                <<<"$all_svcs_x")"
            if [[ -n "$dep_hc" ]]; then
                printf '      %s:\n        condition: service_healthy\n' "$dep"
            else
                printf '      %s:\n        condition: service_started\n' "$dep"
            fi
        done < <(jq -r '.depends_on // [] | .[]?' <<<"$svc")

        # healthcheck — emit the full block when a [service.healthcheck] is defined.
        local xhc_test xhc_interval xhc_timeout xhc_retries xhc_start
        xhc_test="$(    jq -r '.healthcheck.test         // ""' <<<"$svc")"
        xhc_interval="$(jq -r '.healthcheck.interval     // ""' <<<"$svc")"
        xhc_timeout="$( jq -r '.healthcheck.timeout      // ""' <<<"$svc")"
        xhc_retries="$( jq -r '.healthcheck.retries      // ""' <<<"$svc")"
        xhc_start="$(   jq -r '.healthcheck.start_period // ""' <<<"$svc")"
        if [[ -n "$xhc_test" ]]; then
            printf '    healthcheck:\n'
            printf '      test: ["CMD-SHELL", "%s"]\n' "$xhc_test"
            [[ -n "$xhc_interval" ]] && printf '      interval: %s\n'     "$xhc_interval"
            [[ -n "$xhc_timeout"  ]] && printf '      timeout: %s\n'      "$xhc_timeout"
            [[ -n "$xhc_retries"  ]] && printf '      retries: %s\n'      "$xhc_retries"
            [[ -n "$xhc_start"    ]] && printf '      start_period: %s\n' "$xhc_start"
        fi
    done

    # Networks — mirror the [network.X] keys as top-level compose networks.
    local nets net
    nets="$(jq -r '.network // {} | keys[]?' <<<"$cfg")"
    if [[ -z "$nets" ]]; then
        printf 'networks:\n  default:\n    driver: bridge\n'
    else
        printf 'networks:\n'
        for net in $nets; do
            local d; d="$(jq -r --arg n "$net" '.network[$n].driver // "bridge"' <<<"$cfg")"
            printf '  %s:\n    driver: %s\n' "$net" "$d"
        done
    fi

    # Declare every named volume that appeared in any service's volumes list.
    if (( ${#named_volumes[@]} > 0 )); then
        printf 'volumes:\n'
        local vn
        for vn in "${!named_volumes[@]}"; do
            printf '  %s:\n' "$vn"
        done
    fi
}

# ─── CLI parsing ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
$LAB_PROG $LAB_VERSION — docker container & topology management (LAB_CREATE_V2 phase 3)

USAGE
  $LAB_PROG build    --tag IMG  [--backend buildx|from-chroot] [--context DIR | --chroot PATH] [--arch A]
  $LAB_PROG push     <tag> | --tag TAG              [--arch A]  # push image to a registry
  $LAB_PROG run      --name N   [--image IMG | --chroot PATH | --context DIR] [opts...]
  $LAB_PROG up       --config topology.toml|compose.yml
  $LAB_PROG down     --lab NAME | --config topology.toml|compose.yml
  $LAB_PROG exec     <name|lab/service> [-- cmd args...]
  $LAB_PROG logs     <name|lab/service> [--follow]
  $LAB_PROG status   [<name|lab>]
  $LAB_PROG list     [--lab NAME]
  $LAB_PROG inspect  <name|lab/service> [--json]
  $LAB_PROG destroy  <name|lab/service> [--force]
  $LAB_PROG export   --config topology.toml|compose.yml [--format compose]   # emit compose YAML
  $LAB_PROG version | help

BUILD / RUN OPTIONS
  --tag       IMAGE_TAG               (build target)
  --backend   {buildx|from-chroot|from-tarball}    (default for build: buildx)
  --context   PATH                    (buildx: directory containing Dockerfile)
  --chroot    PATH                    (from-chroot: a Phase-1 chroot tree; must be user-readable)
  --tarball   PATH                    (from-tarball: a .tar / .tar.gz produced by lab-chroot export-tarball)
  --arch      {x86_64|aarch64|armv7l|ppc64le|riscv64|s390x}   (default: host arch)
  --image     IMAGE_TAG               (run: pull/use this image)
  --name      CONTAINER_NAME          (run: short name; container becomes lab-<name>)
  --network   NET                     (run: attach to existing docker network)
  --hostname  H                       (run)
  --ports     "8080:80,5432:5432"     (run)
  --env       "K1=V1,K2=V2"           (run)
  --volumes   "src:dst,src2:dst2"     (run)
  --detach                            (run: -d)
  --rm                                (run: --rm)
  --tty                               (run: -it)
  --follow                            (logs: -f)
  --lab       NAME                    (list/down/status: scope to one lab)
  --config    FILE                    (up/down/export: topology .toml or docker-compose .yml/.yaml)
  --format    FMT                     (export: compose — the only format, also the default)
  --force                             (destroy)

ENVIRONMENT
  LAB_LOG_LEVEL  debug|info|warn|error  (default: info)

EXAMPLES
  $LAB_PROG run --name nginx1 --image nginx:alpine --ports 8080:80 --detach
  $LAB_PROG build --tag mychroot:latest --backend from-chroot --chroot /var/jails/busybox
  $LAB_PROG build --tag myimg:arm64 --backend buildx --context ./app --arch aarch64
  $LAB_PROG push myapp:latest
  $LAB_PROG up     --config examples/docker-3svc-topology.toml
  $LAB_PROG up     --config examples/docker-compose.yml          # compose YAML also accepted
  $LAB_PROG list   --lab demo
  $LAB_PROG status demo
  $LAB_PROG export --config examples/docker-3svc-topology.toml --format compose > demo-compose.yml
  $LAB_PROG down   --lab demo
EOF
}

POS_ARGS=()
EXTRA_ARGS=()

parse_args() {
    OPT_CONFIG=""
    OPT_TAG="" OPT_BACKEND="" OPT_CONTEXT="" OPT_CHROOT="" OPT_TARBALL=""
    OPT_NAME="" OPT_IMAGE="" OPT_ARCH=""
    OPT_NETWORK="" OPT_HOSTNAME=""
    OPT_PORTS="" OPT_ENV="" OPT_VOLUMES=""
    OPT_DETACH="" OPT_RM="" OPT_TTY=""
    OPT_FOLLOW=""
    OPT_LAB=""
    OPT_FORCE=""
    OPT_FORMAT=""
    OPT_JSON=""

    [[ $# -eq 0 ]] && { usage; exit 0; }
    SUBCMD="$1"; shift

    local seen_doubledash=0
    while [[ $# -gt 0 ]]; do
        if (( seen_doubledash )); then EXTRA_ARGS+=("$1"); shift; continue; fi
        case "$1" in
            --)             seen_doubledash=1; shift ;;
            --config)       OPT_CONFIG="$2"; shift 2 ;;
            --tag)          OPT_TAG="$2"; shift 2 ;;
            --backend)      OPT_BACKEND="$2"; shift 2 ;;
            --context)      OPT_CONTEXT="$2"; shift 2 ;;
            --chroot)       OPT_CHROOT="$2"; shift 2 ;;
            --tarball)      OPT_TARBALL="$2"; shift 2 ;;
            --name)         OPT_NAME="$2"; shift 2 ;;
            --image)        OPT_IMAGE="$2"; shift 2 ;;
            --arch)         OPT_ARCH="$2"; shift 2 ;;
            --network)      OPT_NETWORK="$2"; shift 2 ;;
            --hostname)     OPT_HOSTNAME="$2"; shift 2 ;;
            --ports)        OPT_PORTS="$2"; shift 2 ;;
            --env)          OPT_ENV="$2"; shift 2 ;;
            --volumes)      OPT_VOLUMES="$2"; shift 2 ;;
            --detach|-d)    OPT_DETACH=1; shift ;;
            --rm)           OPT_RM=1; shift ;;
            --tty|-t)       OPT_TTY=1; shift ;;
            --follow|-f)    OPT_FOLLOW=1; shift ;;
            --lab)          OPT_LAB="$2"; shift 2 ;;
            --format)       OPT_FORMAT="$2"; shift 2 ;;
            --json)         OPT_JSON=1; shift ;;
            --force)        OPT_FORCE=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            -v|--version)   printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION"; exit 0 ;;
            -*)             die "unknown option: $1 (try --help)" ;;
            *)              POS_ARGS+=("$1"); shift ;;
        esac
    done
}

main() {
    parse_args "$@"
    case "$SUBCMD" in
        build)   cmd_build   ;;
        push)    cmd_push    ;;
        run)     cmd_run     ;;
        up)      cmd_up      ;;
        down)    cmd_down    ;;
        exec)    cmd_exec    ;;
        logs)    cmd_logs    ;;
        status)  cmd_status  ;;
        list)    cmd_list    ;;
        inspect) cmd_inspect ;;
        destroy) cmd_destroy ;;
        export)  cmd_export  ;;
        help)    usage       ;;
        version) printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION" ;;
        *)       usage; die "unknown subcommand: $SUBCMD" ;;
    esac
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
