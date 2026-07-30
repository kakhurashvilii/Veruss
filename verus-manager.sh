#!/bin/sh
set -u

# Verus ccminer all-in-one manager
# Commands: setup, install, start, stop, restart, status, logs,
#           service-install, service-remove, uninstall, menu

APP_NAME="verus"
BASE_DIR="${BASE_DIR:-/root/verus}"
BIN_DIR="$BASE_DIR/bin"
RUN_DIR="$BASE_DIR/run"
LOG_DIR="$BASE_DIR/logs"
CONF_FILE="$BASE_DIR/verus.conf"
MINER="$BIN_DIR/ccminer"
MINER_LINK="$BASE_DIR/ccminer"
LOG_FILE="$LOG_DIR/ccminer.log"
WRAPPER_PID_FILE="$RUN_DIR/verus-wrapper.pid"
MINER_PID_FILE="$RUN_DIR/ccminer.pid"
LOCK_DIR="$RUN_DIR/verus.lock"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
SYSTEM_BIN="/usr/local/sbin/verus"
SERVICE_NAME="verus-miner"
REPO_URL="https://github.com/monkins1010/ccminer.git"

# ---------- UI ----------
if [ -t 1 ]; then
    C_RESET='\033[0m'
    C_RED='\033[1;31m'
    C_GREEN='\033[1;32m'
    C_YELLOW='\033[1;33m'
    C_BLUE='\033[1;34m'
    C_CYAN='\033[1;36m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

info()  { printf "%b[INFO]%b %s\n" "$C_CYAN" "$C_RESET" "$*"; }
ok()    { printf "%b[ OK ]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf "%b[WARN]%b %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
error() { printf "%b[FAIL]%b %s\n" "$C_RED" "$C_RESET" "$*" >&2; }

need_root() {
    [ "$(id -u)" -eq 0 ] || {
        error "Run as root."
        exit 1
    }
}

banner() {
    printf "%b" "$C_BLUE"
    cat <<'EOF'
 __     __                    __  __ _
 \ \   / /__ _ __ _   _ ___ |  \/  (_)_ __   ___ _ __
  \ \ / / _ \ '__| | | / __|| |\/| | | '_ \ / _ \ '__|
   \ V /  __/ |  | |_| \__ \| |  | | | | | |  __/ |
    \_/ \___|_|   \__,_|___/|_|  |_|_|_| |_|\___|_|
EOF
    printf "%b\n" "$C_RESET"
}

usage() {
    cat <<EOF
Usage: $0 COMMAND [VALUE]

Commands:
  setup                  Enter wallet, worker, pool and thread count
  config                 Show current configuration
  install [--force]      Install dependencies and build ccminer
  start [threads]        Start in background; terminal may be closed
  run                    Internal foreground supervisor for services
  stop                   Stop miner and supervisor
  restart [threads]      Restart miner
  status                 Show process and recent log status
  logs [lines]           Follow log; default 100 lines
  service-install        Enable automatic startup after reboot
  service-remove         Remove automatic startup service
  uninstall              Stop and completely remove miner files
  menu                    Interactive menu
  help                    Show this help

Examples:
  $0 setup
  $0 install --force
  $0 start 4
  $0 status
  $0 logs 50
  $0 service-install
EOF
}

# ---------- config ----------
mkdir_safe() {
    mkdir -p "$BASE_DIR" "$BIN_DIR" "$RUN_DIR" "$LOG_DIR"
    chmod 700 "$BASE_DIR" "$BIN_DIR" "$RUN_DIR" "$LOG_DIR" 2>/dev/null || true
}

quote_value() {
    # Single-quote a shell value safely.
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

write_config() {
    _wallet="$1"
    _worker="$2"
    _pool="$3"
    _threads="$4"
    _delay="$5"
    _retries="$6"
    _stack="$7"

    mkdir_safe
    {
        printf 'WALLET=%s\n' "$(quote_value "$_wallet")"
        printf 'WORKER_NAME=%s\n' "$(quote_value "$_worker")"
        printf 'POOL=%s\n' "$(quote_value "$_pool")"
        printf 'THREADS=%s\n' "$(quote_value "$_threads")"
        printf 'RESTART_DELAY=%s\n' "$(quote_value "$_delay")"
        printf 'MAX_START_RETRIES=%s\n' "$(quote_value "$_retries")"
        printf 'THREAD_STACK_BYTES=%s\n' "$(quote_value "$_stack")"
        printf 'BUILD_PROFILE=%s\n' "$(quote_value "safe")"
    } > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
}

load_config() {
    WALLET=""
    WORKER_NAME="AndroidMonitor"
    POOL="stratum+tcp://verus.farm:9999"
    THREADS="2"
    RESTART_DELAY="10"
    MAX_START_RETRIES="30"
    THREAD_STACK_BYTES="8388608"
    BUILD_PROFILE="safe"

    if [ -r "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONF_FILE"
    fi

    [ -n "${THREADS_OVERRIDE:-}" ] && THREADS="$THREADS_OVERRIDE"

    case "$THREADS" in ''|*[!0-9]*|0) error "THREADS must be a positive integer."; return 1 ;; esac
    case "$RESTART_DELAY" in ''|*[!0-9]*) error "RESTART_DELAY must be an integer."; return 1 ;; esac
    case "$MAX_START_RETRIES" in ''|*[!0-9]*|0) error "MAX_START_RETRIES must be positive."; return 1 ;; esac
    case "$THREAD_STACK_BYTES" in ''|*[!0-9]*) error "THREAD_STACK_BYTES must be an integer."; return 1 ;; esac

    RAW_ARCH="$(uname -m 2>/dev/null || echo unknown)"
    case "$RAW_ARCH" in
        aarch64|arm64) ARCH="arm64"; SOURCE_BRANCH="ARM" ;;
        armv8l|armv7l|armv7|armhf) ARCH="armv7"; SOURCE_BRANCH="ARM" ;;
        x86_64|amd64) ARCH="x86_64"; SOURCE_BRANCH="Verus2.2" ;;
        i386|i486|i586|i686|x86) ARCH="x86"; SOURCE_BRANCH="Verus2.2" ;;
        *) error "Unsupported architecture: $RAW_ARCH"; return 1 ;;
    esac

    HOST_PART="$(hostname 2>/dev/null || echo host)"
    HOST_PART="$(printf '%s' "$HOST_PART" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-24)"
    WORKER="${WORKER_NAME}-${ARCH}-${HOST_PART}"
    return 0
}

setup_config() {
    need_root
    mkdir_safe
    load_config 2>/dev/null || true

    banner
    info "Enter the important values. Press Enter to keep the value in brackets."

    printf "Wallet [%s]: " "${WALLET:-}"
    IFS= read -r input_wallet || true
    [ -n "$input_wallet" ] || input_wallet="${WALLET:-}"

    while [ -z "$input_wallet" ]; do
        warn "Wallet cannot be empty."
        printf "Wallet: "
        IFS= read -r input_wallet || true
    done

    printf "Worker name [%s]: " "${WORKER_NAME:-AndroidMonitor}"
    IFS= read -r input_worker || true
    [ -n "$input_worker" ] || input_worker="${WORKER_NAME:-AndroidMonitor}"

    printf "Pool URL [%s]: " "${POOL:-stratum+tcp://verus.farm:9999}"
    IFS= read -r input_pool || true
    [ -n "$input_pool" ] || input_pool="${POOL:-stratum+tcp://verus.farm:9999}"

    printf "Mining threads [%s]: " "${THREADS:-2}"
    IFS= read -r input_threads || true
    [ -n "$input_threads" ] || input_threads="${THREADS:-2}"
    case "$input_threads" in ''|*[!0-9]*|0) error "Invalid thread count."; exit 1 ;; esac

    printf "Restart delay seconds [%s]: " "${RESTART_DELAY:-10}"
    IFS= read -r input_delay || true
    [ -n "$input_delay" ] || input_delay="${RESTART_DELAY:-10}"
    case "$input_delay" in ''|*[!0-9]*) error "Invalid restart delay."; exit 1 ;; esac

    write_config \
        "$input_wallet" "$input_worker" "$input_pool" "$input_threads" \
        "$input_delay" "${MAX_START_RETRIES:-30}" "${THREAD_STACK_BYTES:-8388608}"

    ok "Configuration saved: $CONF_FILE"
    show_config
}

show_config() {
    load_config || exit 1
    cat <<EOF
Configuration
-------------
Wallet:       $WALLET
Worker:       $WORKER
Pool:         $POOL
Threads:      $THREADS
Architecture: $RAW_ARCH ($ARCH)
Restart:      ${RESTART_DELAY}s
Stack:        $THREAD_STACK_BYTES bytes
Config file:  $CONF_FILE
EOF
}

ensure_config() {
    if [ ! -r "$CONF_FILE" ]; then
        warn "Configuration does not exist yet."
        setup_config
    fi
    load_config
}

# ---------- process helpers ----------
read_pid() {
    [ -r "$1" ] || return 1
    _pid="$(cat "$1" 2>/dev/null || true)"
    case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$_pid"
}

pid_alive() {
    kill -0 "$1" 2>/dev/null
}

pid_contains() {
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -Fq -- "$2"
}

binary_healthy() {
    [ -x "$MINER" ] || return 1
    if command -v ldd >/dev/null 2>&1; then
        ! ldd "$MINER" 2>&1 | grep -Eq 'not found|Error loading shared library'
    fi
}

# ---------- install/build ----------
install_dependencies() {
    info "Installing build dependencies..."
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add --no-cache \
            bash git curl ca-certificates build-base autoconf automake libtool \
            pkgconf curl-dev openssl-dev jansson-dev zlib-dev linux-headers \
            file procps coreutils util-linux binutils
        update-ca-certificates 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends \
            bash git curl ca-certificates build-essential autoconf automake libtool \
            pkg-config libcurl4-openssl-dev libssl-dev libjansson-dev zlib1g-dev \
            file procps util-linux binutils
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y bash git curl ca-certificates gcc gcc-c++ make autoconf automake \
            libtool pkgconf-pkg-config libcurl-devel openssl-devel jansson-devel \
            zlib-devel file procps-ng util-linux binutils
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bash git curl ca-certificates gcc gcc-c++ make autoconf automake \
            libtool pkgconfig libcurl-devel openssl-devel jansson-devel zlib-devel \
            file procps-ng util-linux binutils
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed bash git curl ca-certificates base-devel \
            autoconf automake libtool pkgconf openssl jansson zlib file procps-ng \
            util-linux binutils
    else
        error "Unsupported package manager."
        return 1
    fi
}

build_flags() {
    case "$ARCH" in
        arm64) printf '%s' '-O2 -pipe -march=armv8-a+crypto -fno-strict-aliasing' ;;
        armv7) printf '%s' '-O2 -pipe -march=armv7-a -mfpu=neon -fno-strict-aliasing' ;;
        x86_64) printf '%s' '-O2 -pipe -march=x86-64 -mtune=generic -fno-strict-aliasing' ;;
        x86) printf '%s' '-O2 -pipe -march=i686 -mtune=generic -fno-strict-aliasing' ;;
    esac
}

apply_source_patches() {
    SRC_FILE="$1/ccminer.cpp"

    # Reduce aggressive optimization in upstream helper files.
    find "$1" -maxdepth 2 -type f \
        \( -name 'Makefile.am' -o -name 'configure.sh' -o -name 'build.sh' \) \
        -exec sed -i 's/-O3/-O2/g' {} \; 2>/dev/null || true

    if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "armv7" ]; then
        [ -f "$SRC_FILE" ] || { error "Missing source file: $SRC_FILE"; return 1; }

        # Fix pointer-size bug first.
        sed -i 's/sizeof(&set)/sizeof(set)/g' "$SRC_FILE"

        # Fix affinity race: the newly-created thread must set affinity on itself.
        if grep -q 'pthread_setaffinity_np(thr_info\[id\]\.pth' "$SRC_FILE"; then
            sed -i \
                's/pthread_setaffinity_np(thr_info\[id\]\.pth, sizeof(set), &set);/sched_setaffinity(0, sizeof(set), \&set);/g' \
                "$SRC_FILE"
        fi

        if grep -q 'pthread_setaffinity_np(thr_info\[id\]\.pth' "$SRC_FILE"; then
            error "Affinity race patch did not apply."
            return 1
        fi

        grep -q 'sched_setaffinity(0, sizeof(set), &set);' "$SRC_FILE" || {
            error "Patched affinity call was not found."
            return 1
        }

        ok "Applied ARM affinity race patch."
    fi
}

install_miner() {
    need_root
    ensure_config

    FORCE="0"
    [ "${1:-}" = "--force" ] && FORCE="1"

    if binary_healthy && [ "$FORCE" != "1" ]; then
        ok "ccminer is already installed: $MINER"
        info "Use '$0 install --force' for a clean rebuild."
        return 0
    fi

    stop_miner >/dev/null 2>&1 || true
    install_dependencies
    mkdir_safe

    FREE_KB="$(df -Pk "${TMPDIR:-/tmp}" 2>/dev/null | awk 'NR==2 {print $4}')"
    case "$FREE_KB" in ''|*[!0-9]*) ;; *)
        [ "$FREE_KB" -ge 524288 ] || {
            error "At least 512 MiB free space is required in ${TMPDIR:-/tmp}."
            exit 1
        }
    esac

    BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verus-build.XXXXXX")"
    SOURCE_DIR="$BUILD_ROOT/ccminer-source"
    trap 'rm -rf "$BUILD_ROOT" 2>/dev/null || true' EXIT INT TERM HUP

    info "Cloning branch $SOURCE_BRANCH for $RAW_ARCH..."
    git clone --depth 1 --single-branch --branch "$SOURCE_BRANCH" \
        --recurse-submodules "$REPO_URL" "$SOURCE_DIR"

    apply_source_patches "$SOURCE_DIR"

    FLAGS="$(build_flags) -D_REENTRANT -falign-functions=16 -falign-jumps=16 -falign-labels=16 -Wno-deprecated-declarations"
    LINK_FLAGS=""
    if ldd --version 2>&1 | grep -qi musl || ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
        LINK_FLAGS="-Wl,-z,stack-size=$THREAD_STACK_BYTES"
    fi

    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    case "$JOBS" in ''|*[!0-9]*) JOBS=1 ;; esac
    [ "$JOBS" -le 4 ] || JOBS=4

    info "Building with $JOBS job(s)..."
    info "CFLAGS: $FLAGS"
    [ -z "$LINK_FLAGS" ] || info "LDFLAGS: $LINK_FLAGS"

    cd "$SOURCE_DIR"
    chmod +x autogen.sh configure.sh build.sh 2>/dev/null || true
    make distclean >/dev/null 2>&1 || true
    ./autogen.sh
    ./configure CFLAGS="$FLAGS" CXXFLAGS="$FLAGS" LDFLAGS="$LINK_FLAGS"
    make -j"$JOBS"

    [ -x "$SOURCE_DIR/ccminer" ] || {
        error "Build finished without a ccminer binary."
        exit 1
    }

    if command -v ldd >/dev/null 2>&1 && \
       ldd "$SOURCE_DIR/ccminer" 2>&1 | grep -Eq 'not found|Error loading shared library'; then
        error "Built binary has unresolved shared libraries."
        ldd "$SOURCE_DIR/ccminer" 2>&1 || true
        exit 1
    fi

    install -m 755 "$SOURCE_DIR/ccminer" "$MINER.new"
    mv -f "$MINER.new" "$MINER"
    ln -sfn "$MINER" "$MINER_LINK"
    sync 2>/dev/null || true

    ok "ccminer installed successfully."
    file "$MINER" 2>/dev/null || true
    if command -v readelf >/dev/null 2>&1; then
        readelf -W -l "$MINER" 2>/dev/null | grep GNU_STACK || true
    fi

    cd /
    rm -rf "$BUILD_ROOT" 2>/dev/null || true
    trap - EXIT INT TERM HUP
}

# ---------- runtime ----------
cleanup_runtime() {
    MINER_PID="$(read_pid "$MINER_PID_FILE" 2>/dev/null || true)"
    if [ -n "$MINER_PID" ] && pid_alive "$MINER_PID"; then
        kill -TERM "$MINER_PID" 2>/dev/null || true
        _wait=0
        while pid_alive "$MINER_PID" && [ "$_wait" -lt 10 ]; do
            _wait=$((_wait + 1))
            sleep 1
        done
        pid_alive "$MINER_PID" && kill -KILL "$MINER_PID" 2>/dev/null || true
    fi
    rm -f "$MINER_PID_FILE" "$WRAPPER_PID_FILE"
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

run_supervisor() {
    ensure_config
    binary_healthy || {
        error "ccminer is missing. Run: $0 install"
        exit 1
    }

    mkdir_safe
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        OLD_PID="$(read_pid "$WRAPPER_PID_FILE" 2>/dev/null || true)"
        if [ -n "$OLD_PID" ] && pid_alive "$OLD_PID" && pid_contains "$OLD_PID" " run"; then
            error "Supervisor is already running with PID $OLD_PID."
            exit 0
        fi
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        mkdir "$LOCK_DIR" || exit 1
    fi

    echo "$$" > "$WRAPPER_PID_FILE"
    STOP_REQUESTED=0
    CURRENT_MINER_PID=""

    on_signal() {
        STOP_REQUESTED=1
        [ -z "$CURRENT_MINER_PID" ] || kill -TERM "$CURRENT_MINER_PID" 2>/dev/null || true
    }
    on_exit() { cleanup_runtime; }
    trap on_signal INT TERM HUP
    trap on_exit EXIT

    ulimit -s unlimited 2>/dev/null || true

    echo "=================================================="
    echo "Verus miner supervisor"
    echo "Pool:    $POOL"
    echo "Wallet:  $WALLET"
    echo "Worker:  $WORKER"
    echo "Threads: $THREADS"
    echo "=================================================="

    RAPID_FAILURES=0
    while [ "$STOP_REQUESTED" -eq 0 ]; do
        START_TIME="$(date +%s 2>/dev/null || echo 0)"

        "$MINER" \
            -a verus \
            -o "$POOL" \
            -u "${WALLET}.${WORKER}" \
            -p x \
            -t "$THREADS" &

        CURRENT_MINER_PID=$!
        echo "$CURRENT_MINER_PID" > "$MINER_PID_FILE"
        echo "ccminer started: PID=$CURRENT_MINER_PID"

        wait "$CURRENT_MINER_PID"
        EXIT_CODE=$?
        END_TIME="$(date +%s 2>/dev/null || echo 0)"
        RUNTIME=$((END_TIME - START_TIME))
        CURRENT_MINER_PID=""
        rm -f "$MINER_PID_FILE"

        [ "$STOP_REQUESTED" -eq 0 ] || break

        echo "ccminer stopped: exit=$EXIT_CODE runtime=${RUNTIME}s"
        [ "$EXIT_CODE" -eq 139 ] && echo "Detected SIGSEGV; retrying without deleting the binary."

        if [ "$RUNTIME" -lt 20 ]; then
            RAPID_FAILURES=$((RAPID_FAILURES + 1))
        else
            RAPID_FAILURES=0
        fi

        if [ "$RAPID_FAILURES" -ge "$MAX_START_RETRIES" ]; then
            error "Miner failed rapidly $RAPID_FAILURES times. Supervisor stopped."
            exit 1
        fi

        echo "Restarting in ${RESTART_DELAY}s..."
        sleep "$RESTART_DELAY" || true
    done
}

start_miner() {
    need_root
    ensure_config

    if [ -n "${1:-}" ]; then
        case "$1" in ''|*[!0-9]*|0) error "Invalid thread count: $1"; exit 1 ;; esac
        THREADS="$1"
    fi

    if ! binary_healthy; then
        warn "ccminer is not installed. Installing it now..."
        install_miner
    fi

    OLD_PID="$(read_pid "$WRAPPER_PID_FILE" 2>/dev/null || true)"
    if [ -n "$OLD_PID" ] && pid_alive "$OLD_PID"; then
        ok "Miner supervisor is already running: PID=$OLD_PID"
        return 0
    fi

    rm -f "$WRAPPER_PID_FILE" "$MINER_PID_FILE"
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    : >> "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    # Install this file as a stable command so services and nohup do not depend
    # on the temporary download location.
    if [ "$SELF_PATH" != "$SYSTEM_BIN" ]; then
        install -m 755 "$SELF_PATH" "$SYSTEM_BIN"
    fi

    nohup env BASE_DIR="$BASE_DIR" THREADS_OVERRIDE="$THREADS" \
        "$SYSTEM_BIN" run >> "$LOG_FILE" 2>&1 &
    START_PID=$!
    sleep 3

    WRAPPER_PID="$(read_pid "$WRAPPER_PID_FILE" 2>/dev/null || true)"
    if [ -n "$WRAPPER_PID" ] && pid_alive "$WRAPPER_PID"; then
        ok "Verus miner started in background."
        printf "Supervisor PID: %s\nThreads: %s\nLog: %s\n" "$WRAPPER_PID" "$THREADS" "$LOG_FILE"
        return 0
    fi

    if pid_alive "$START_PID"; then
        warn "Supervisor is still starting: PID=$START_PID"
        return 0
    fi

    error "Miner failed to start."
    tail -n 50 "$LOG_FILE" 2>/dev/null || true
    exit 1
}

stop_miner() {
    need_root
    WRAPPER_PID="$(read_pid "$WRAPPER_PID_FILE" 2>/dev/null || true)"
    MINER_PID="$(read_pid "$MINER_PID_FILE" 2>/dev/null || true)"

    if [ -z "$WRAPPER_PID" ] && [ -z "$MINER_PID" ]; then
        info "Miner is not running."
        cleanup_runtime
        return 0
    fi

    [ -z "$WRAPPER_PID" ] || {
        info "Stopping supervisor PID $WRAPPER_PID..."
        kill -TERM "$WRAPPER_PID" 2>/dev/null || true
    }

    _wait=0
    while [ "$_wait" -lt 15 ]; do
        _alive=0
        [ -z "$WRAPPER_PID" ] || ! pid_alive "$WRAPPER_PID" || _alive=1
        [ -z "$MINER_PID" ] || ! pid_alive "$MINER_PID" || _alive=1
        [ "$_alive" -eq 0 ] && break
        _wait=$((_wait + 1))
        sleep 1
    done

    [ -z "$MINER_PID" ] || ! pid_alive "$MINER_PID" || kill -KILL "$MINER_PID" 2>/dev/null || true
    [ -z "$WRAPPER_PID" ] || ! pid_alive "$WRAPPER_PID" || kill -KILL "$WRAPPER_PID" 2>/dev/null || true
    cleanup_runtime
    ok "Verus miner stopped."
}

status_miner() {
    ensure_config
    WRAPPER_PID="$(read_pid "$WRAPPER_PID_FILE" 2>/dev/null || true)"
    MINER_PID="$(read_pid "$MINER_PID_FILE" 2>/dev/null || true)"

    echo "Verus status"
    echo "------------"
    echo "Pool:       $POOL"
    echo "Worker:     $WORKER"
    echo "Threads:    $THREADS"
    echo "Binary:     $MINER"

    if [ -n "$WRAPPER_PID" ] && pid_alive "$WRAPPER_PID"; then
        printf "%bSupervisor:%b RUNNING (PID %s)\n" "$C_GREEN" "$C_RESET" "$WRAPPER_PID"
    else
        printf "%bSupervisor:%b STOPPED\n" "$C_RED" "$C_RESET"
    fi

    if [ -n "$MINER_PID" ] && pid_alive "$MINER_PID"; then
        printf "%bMiner:%b      RUNNING (PID %s)\n" "$C_GREEN" "$C_RESET" "$MINER_PID"
        ps -o pid,ppid,etime,%cpu,%mem,args -p "$MINER_PID" 2>/dev/null || true
    else
        printf "%bMiner:%b      STOPPED\n" "$C_RED" "$C_RESET"
    fi

    if binary_healthy; then
        file "$MINER" 2>/dev/null || true
    else
        echo "Binary:     MISSING/INCOMPATIBLE"
    fi

    echo
    echo "Recent log"
    echo "----------"
    tail -n 20 "$LOG_FILE" 2>/dev/null || echo "No log yet."
}

show_logs() {
    LINES="${1:-100}"
    case "$LINES" in ''|*[!0-9]*) error "Log line count must be an integer."; exit 1 ;; esac
    mkdir_safe
    touch "$LOG_FILE"
    tail -n "$LINES" -f "$LOG_FILE"
}

# ---------- service ----------
install_service() {
    need_root
    ensure_config
    install -m 755 "$SELF_PATH" "$SYSTEM_BIN"

    if command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ]; then
        cat > "/etc/init.d/$SERVICE_NAME" <<EOF
#!/sbin/openrc-run
name="Verus Miner"
description="Verus ccminer supervisor"
command="$SYSTEM_BIN"
command_args="run"
command_background="yes"
pidfile="$RUN_DIR/openrc.pid"
output_log="$LOG_FILE"
error_log="$LOG_FILE"

start_pre() {
    checkpath --directory --mode 0700 "$RUN_DIR"
    checkpath --directory --mode 0700 "$LOG_DIR"
}

depend() {
    need net
    after firewall
}
EOF
        chmod 755 "/etc/init.d/$SERVICE_NAME"
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
        ok "OpenRC service installed and enabled at boot."
        info "Start:   rc-service $SERVICE_NAME start"
        info "Status:  rc-service $SERVICE_NAME status"
        info "Restart: rc-service $SERVICE_NAME restart"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=Verus ccminer supervisor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SYSTEM_BIN run
Restart=on-failure
RestartSec=15
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME.service"
        ok "systemd service installed and enabled at boot."
        info "Start:   systemctl start $SERVICE_NAME"
        info "Status:  systemctl status $SERVICE_NAME"
        info "Restart: systemctl restart $SERVICE_NAME"
        return 0
    fi

    error "Neither OpenRC nor systemd was detected."
    exit 1
}

remove_service() {
    need_root
    if command -v rc-service >/dev/null 2>&1 && [ -f "/etc/init.d/$SERVICE_NAME" ]; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/$SERVICE_NAME"
        ok "OpenRC service removed."
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        systemctl disable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$SERVICE_NAME.service"
        systemctl daemon-reload
        ok "systemd service removed."
    fi
}

uninstall_all() {
    need_root
    printf "Remove Verus miner, config, binary and logs? [y/N]: "
    IFS= read -r answer || true
    case "$answer" in y|Y|yes|YES) ;; *) info "Cancelled."; return 0 ;; esac

    stop_miner >/dev/null 2>&1 || true
    remove_service >/dev/null 2>&1 || true
    rm -rf "$BASE_DIR"
    rm -f "$SYSTEM_BIN"
    ok "Verus miner was completely removed."
}

# ---------- menu ----------
menu() {
    while :; do
        banner
        cat <<'EOF'
1) Configure wallet / worker / pool / threads
2) Install or rebuild ccminer
3) Start in background
4) Stop
5) Restart
6) Status
7) Live logs
8) Enable automatic startup after reboot
9) Remove automatic startup service
0) Complete uninstall
q) Exit
EOF
        printf "Choose: "
        IFS= read -r choice || exit 0
        case "$choice" in
            1) setup_config ;;
            2) printf "Force clean rebuild? [y/N]: "; IFS= read -r a || true; case "$a" in y|Y) install_miner --force ;; *) install_miner ;; esac ;;
            3) printf "Threads [config value]: "; IFS= read -r t || true; start_miner "$t" ;;
            4) stop_miner ;;
            5) printf "Threads [config value]: "; IFS= read -r t || true; stop_miner; start_miner "$t" ;;
            6) status_miner ;;
            7) show_logs 100 ;;
            8) install_service ;;
            9) remove_service ;;
            0) uninstall_all ;;
            q|Q) exit 0 ;;
            *) warn "Unknown choice." ;;
        esac
        printf "\nPress Enter to continue..."
        IFS= read -r _ || true
    done
}

# ---------- command router ----------
COMMAND="${1:-menu}"
case "$COMMAND" in
    setup) setup_config ;;
    config) show_config ;;
    install) install_miner "${2:-}" ;;
    start) start_miner "${2:-}" ;;
    run) run_supervisor ;;
    stop) stop_miner ;;
    restart) stop_miner; start_miner "${2:-}" ;;
    status) status_miner ;;
    logs) show_logs "${2:-100}" ;;
    service-install) install_service ;;
    service-remove) remove_service ;;
    uninstall) uninstall_all ;;
    menu) menu ;;
    help|-h|--help) usage ;;
    *) error "Unknown command: $COMMAND"; usage; exit 2 ;;
esac
