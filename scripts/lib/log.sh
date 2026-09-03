# scripts/lib/log.sh - color logging helpers for the Aliyun orchestrators
#
# Sourced by the aliyun-*.sh scripts. Not for direct execution.
#
# Provides:
#   log_info, log_warn, log_error, log_debug, log_fatal
#   All log to stderr (so the function's stdout can be captured cleanly).

# Only define once even if sourced multiple times.
if [[ -n "${__QALOS_LOG_SH_LOADED:-}" ]]; then
    return 0
fi
__QALOS_LOG_SH_LOADED=1

# Detect whether stderr is a TTY. If not, drop the color codes.
if [[ -t 2 ]]; then
    : "${COLOR_RED:=$'\033[0;31m'}"
    : "${COLOR_YELLOW:=$'\033[0;33m'}"
    : "${COLOR_GREEN:=$'\033[0;32m'}"
    : "${COLOR_CYAN:=$'\033[0;36m'}"
    : "${COLOR_GREY:=$'\033[0;90m'}"
    : "${COLOR_RESET:=$'\033[0m'}"
else
    COLOR_RED=''; COLOR_YELLOW=''; COLOR_GREEN=''; COLOR_CYAN=''; COLOR_GREY=''; COLOR_RESET=''
fi

# Levels: debug < info < warn < error < fatal
__QALOS_LOG_LEVEL="${__QALOS_LOG_LEVEL:-info}"

_qalos_log() {
    local level="$1"; shift
    local color="$1"; shift
    local label
    case "$level" in
        debug) label="DEBUG" ;;
        info)  label="INFO " ;;
        warn)  label="WARN " ;;
        error) label="ERROR" ;;
        fatal) label="FATAL" ;;
    esac
    # Compare against threshold
    local should_log=0
    case "$__QALOS_LOG_LEVEL" in
        debug) should_log=1 ;;
        info)  [[ "$level" != "debug" ]] && should_log=1 ;;
        warn)  [[ "$level" == "warn" || "$level" == "error" || "$level" == "fatal" ]] && should_log=1 ;;
        error) [[ "$level" == "error" || "$level" == "fatal" ]] && should_log=1 ;;
        fatal) [[ "$level" == "fatal" ]] && should_log=1 ;;
    esac
    if [[ "$should_log" -eq 1 ]]; then
        printf '%s%s%s [%s] %s\n' "$color" "$label" "$COLOR_RESET" "$(date +'%H:%M:%S')" "$*" >&2
    fi
}

log_debug() { _qalos_log debug "$COLOR_GREY"   "$@"; }
log_info()  { _qalos_log info  "$COLOR_CYAN"   "$@"; }
log_warn()  { _qalos_log warn  "$COLOR_YELLOW" "$@"; }
log_error() { _qalos_log error "$COLOR_RED"    "$@"; }
log_fatal() { _qalos_log fatal "$COLOR_RED"    "$@"; exit 1; }
