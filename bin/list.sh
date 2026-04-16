#!/bin/bash
# Mole - List command.
# Lists installed applications and the exact name `mo uninstall` will accept.
# Read-only: no sudo, no deletion, no path-validation surface.
#
# Why a separate "list" command:
#   `mo uninstall` takes an app name as an argument, but users don't always
#   know whether to pass the display name ("Visual Studio Code") or the
#   Homebrew cask token ("visual-studio-code"). This command surfaces both,
#   so the output can be piped/grepped into `mo uninstall <UNINSTALL NAME>`.

set -euo pipefail

# Fix locale issues on non-English systems (matches bin/uninstall.sh).
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/core/common.sh"
# get_brew_cask_name() + is_homebrew_available() - reused so our "uninstall name"
# matches exactly what `mo uninstall` accepts.
source "$SCRIPT_DIR/../lib/uninstall/brew.sh"

trap cleanup_temp_files EXIT INT TERM

# Scan roots match SECURITY_AUDIT.md "Installed-app detection" list.
# Homebrew casks are discovered via the symlinks they drop into /Applications,
# so Caskroom itself does not need to be walked directly.
readonly LIST_SCAN_PATHS=(
    "/Applications"
    "/Applications/Setapp"
    "/System/Applications"
    "$HOME/Applications"
)

# Options (set by parse_list_args)
OUTPUT_FORMAT="text" # auto-switches to "json" when stdout is not a TTY
SORT_BY="name"       # name | size
SOURCE_FILTER="all"  # all | user | system | homebrew | setapp
BREW_ONLY=0

# Parallel arrays (bash 3.2 has no portable associative arrays).
declare -a APP_PATHS=()
declare -a APP_NAMES=()
declare -a APP_BUNDLE_IDS=()
declare -a APP_SOURCES=()   # User | System | Homebrew | Setapp
declare -a APP_UNINSTALL=() # name to pass to `mo uninstall`
declare -a APP_SIZES_KB=()

parse_list_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                OUTPUT_FORMAT="json"
                shift
                ;;
            --sort)
                SORT_BY="${2:-name}"
                shift 2 || true
                ;;
            --sort=*)
                SORT_BY="${1#--sort=}"
                shift
                ;;
            --source)
                SOURCE_FILTER="${2:-all}"
                shift 2 || true
                ;;
            --source=*)
                SOURCE_FILTER="${1#--source=}"
                shift
                ;;
            --brew-only)
                BREW_ONLY=1
                shift
                ;;
            --debug)
                export MO_DEBUG=1
                shift
                ;;
            -h | --help)
                show_list_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_list_help
                exit 1
                ;;
        esac
    done

    # Validate option values early so the user gets a clear error.
    case "$SORT_BY" in
        name | size) ;;
        *)
            log_error "Invalid --sort value: $SORT_BY (expected: name|size)"
            exit 1
            ;;
    esac
    case "$SOURCE_FILTER" in
        all | user | system | homebrew | setapp) ;;
        *)
            log_error "Invalid --source value: $SOURCE_FILTER (expected: all|user|system|homebrew|setapp)"
            exit 1
            ;;
    esac
}

# Resolve the human-readable name. Mirrors bin/uninstall.sh's resolver order:
# CFBundleDisplayName > CFBundleName > basename. Uses plutil (matches project
# convention; `defaults read` is less reliable for nested keys).
list_resolve_display_name() {
    local app_path="$1"
    local fallback="${app_path##*/}"
    fallback="${fallback%.app}"

    local plist="$app_path/Contents/Info.plist"
    if [[ ! -f "$plist" ]]; then
        printf '%s' "$fallback"
        return 0
    fi

    local name=""
    name=$(plutil -extract CFBundleDisplayName raw -o - "$plist" 2> /dev/null || true)
    if [[ -z "$name" ]]; then
        name=$(plutil -extract CFBundleName raw -o - "$plist" 2> /dev/null || true)
    fi

    # plutil sometimes prints "No value at that key path" to stdout on older
    # macOS; guard against that.
    if [[ "$name" == *"No value"* || "$name" == *"CFBundle"* && "${#name}" -gt 64 ]]; then
        name=""
    fi

    [[ -n "$name" ]] && printf '%s' "$name" || printf '%s' "$fallback"
}

list_resolve_bundle_id() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    [[ -f "$plist" ]] || {
        printf ''
        return 0
    }
    local id
    id=$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2> /dev/null || true)
    [[ "$id" == *"No value"* ]] && id=""
    printf '%s' "$id"
}

# Directory size via BSD du -sk (KB). BSD's `-b` does not exist.
list_get_size_kb() {
    local app_path="$1"
    local kb
    kb=$(du -sk "$app_path" 2> /dev/null | awk 'NR==1 {print $1}' || true)
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
    printf '%s' "$kb"
}

list_format_size() {
    local kb="${1:-0}"
    [[ "$kb" =~ ^[0-9]+$ ]] || {
        printf 'N/A'
        return
    }

    if ((kb < 1024)); then
        printf '%dKB' "$kb"
    elif ((kb < 1048576)); then
        printf '%dMB' "$((kb / 1024))"
    else
        # Render as X.YGB without bc/awk floats.
        local gb_tenths=$((kb * 10 / 1048576))
        printf '%d.%dGB' "$((gb_tenths / 10))" "$((gb_tenths % 10))"
    fi
}

# Classify by install location. Homebrew is decided later via cask resolver.
list_classify_source() {
    local app_path="$1"
    case "$app_path" in
        "/Applications/Setapp/"*) printf 'Setapp' ;;
        "/System/Applications/"*) printf 'System' ;;
        "$HOME/Applications/"*) printf 'User' ;;
        "/Applications/"*) printf 'User' ;;
        *) printf 'User' ;;
    esac
}

# Dedup by absolute path. O(n) per insert, fine for ~hundreds of apps.
list_already_seen() {
    local target="$1"
    local i
    for ((i = 0; i < ${#APP_PATHS[@]}; i++)); do
        [[ "${APP_PATHS[i]}" == "$target" ]] && return 0
    done
    return 1
}

list_process_app() {
    local app_path="$1"
    list_already_seen "$app_path" && return 0

    local app_basename="${app_path##*/}"
    local app_stem="${app_basename%.app}"

    local display bundle_id source_label uninstall_name cask=""
    display=$(list_resolve_display_name "$app_path")
    bundle_id=$(list_resolve_bundle_id "$app_path")

    # Ask the existing Homebrew resolver whether this app is cask-managed.
    # On non-Homebrew machines this short-circuits via is_homebrew_available.
    if is_homebrew_available; then
        cask=$(get_brew_cask_name "$app_path" 2> /dev/null || true)
    fi

    if [[ -n "$cask" ]]; then
        source_label="Homebrew"
        uninstall_name="$cask"
    else
        source_label=$(list_classify_source "$app_path")
        # For non-Homebrew apps, `mo uninstall <app name>` already works (see
        # bin/uninstall.sh --help). Prefer the display name for user clarity.
        uninstall_name="$display"
    fi

    # Filters.
    if [[ $BREW_ONLY -eq 1 && "$source_label" != "Homebrew" ]]; then
        return 0
    fi
    case "$SOURCE_FILTER" in
        all) ;;
        user) [[ "$source_label" == "User" ]] || return 0 ;;
        system) [[ "$source_label" == "System" ]] || return 0 ;;
        homebrew) [[ "$source_label" == "Homebrew" ]] || return 0 ;;
        setapp) [[ "$source_label" == "Setapp" ]] || return 0 ;;
    esac

    local size_kb
    size_kb=$(list_get_size_kb "$app_path")

    APP_PATHS+=("$app_path")
    APP_NAMES+=("$display")
    APP_BUNDLE_IDS+=("$bundle_id")
    APP_SOURCES+=("$source_label")
    APP_UNINSTALL+=("$uninstall_name")
    APP_SIZES_KB+=("$size_kb")

    debug_log "Listed: $display [$source_label] uninstall='$uninstall_name' size=${size_kb}KB"
    # Suppress unused-var warning on app_stem; kept for future per-source logic.
    : "$app_stem"
}

list_scan_all() {
    local scan_root app_path
    for scan_root in "${LIST_SCAN_PATHS[@]}"; do
        [[ -d "$scan_root" ]] || continue
        # -maxdepth 1: skip nested .app bundles (helpers embedded in other
        # apps). BSD find supports -maxdepth.
        while IFS= read -r app_path; do
            [[ -n "$app_path" ]] || continue
            [[ -d "$app_path" ]] || continue
            list_process_app "$app_path"
        done < <(find "$scan_root" -maxdepth 1 -name '*.app' -type d 2> /dev/null || true)
    done
}

# Reorder the six parallel arrays together. Build "$key|$idx" pairs, sort,
# then rebuild arrays in the new order. Bash 3.2 safe (no mapfile).
list_sort_apps() {
    local total=${#APP_PATHS[@]}
    ((total > 0)) || return 0

    local -a sort_input=()
    local i key
    for ((i = 0; i < total; i++)); do
        if [[ "$SORT_BY" == "size" ]]; then
            key="${APP_SIZES_KB[i]}"
        else
            # Case-insensitive alphabetical sort.
            key=$(printf '%s' "${APP_NAMES[i]}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        fi
        sort_input+=("${key}|${i}")
    done

    local -a sort_args=()
    # SC2054: -k1,1 / -k1,1nr are sort(1) field specifiers, not multi-element
    # array entries; the comma is required by sort and must not be a separator.
    # shellcheck disable=SC2054
    if [[ "$SORT_BY" == "size" ]]; then
        sort_args=(-t '|' -k1,1nr) # numeric, descending
    else
        sort_args=(-t '|' -k1,1) # lexical, ascending
    fi

    local -a order=()
    local line idx
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        idx="${line##*|}"
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        order+=("$idx")
    done < <(printf '%s\n' "${sort_input[@]}" | sort "${sort_args[@]}")

    # Rebuild arrays in sorted order.
    local -a new_paths=() new_names=() new_bundles=() new_sources=() new_uninst=() new_sizes=()
    for idx in "${order[@]}"; do
        new_paths+=("${APP_PATHS[idx]}")
        new_names+=("${APP_NAMES[idx]}")
        new_bundles+=("${APP_BUNDLE_IDS[idx]}")
        new_sources+=("${APP_SOURCES[idx]}")
        new_uninst+=("${APP_UNINSTALL[idx]}")
        new_sizes+=("${APP_SIZES_KB[idx]}")
    done

    APP_PATHS=("${new_paths[@]}")
    APP_NAMES=("${new_names[@]}")
    APP_BUNDLE_IDS=("${new_bundles[@]}")
    APP_SOURCES=("${new_sources[@]}")
    APP_UNINSTALL=("${new_uninst[@]}")
    APP_SIZES_KB=("${new_sizes[@]}")
}

# Escape a string for JSON. Only the required chars: backslash, quote, and
# C0 whitespace that would break a single-line value.
list_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\n'/ }"
    printf '%s' "$s"
}

list_output_text() {
    local total=${#APP_PATHS[@]}
    if ((total == 0)); then
        printf '\nNo applications matched.\n\n'
        return 0
    fi

    printf '\n'
    printf '%-40s %-30s %-9s %-26s %8s\n' \
        'NAME' 'BUNDLE ID' 'SOURCE' 'UNINSTALL NAME' 'SIZE'
    printf -- '-%.0s' $(seq 1 116)
    printf '\n'

    local i name bundle uninst
    for ((i = 0; i < total; i++)); do
        name="${APP_NAMES[i]}"
        bundle="${APP_BUNDLE_IDS[i]}"
        uninst="${APP_UNINSTALL[i]}"
        # Truncate each column with bash parameter expansion (bash 3.2 safe).
        printf '%-40s %-30s %-9s %-26s %8s\n' \
            "${name:0:38}" \
            "${bundle:0:28}" \
            "${APP_SOURCES[i]}" \
            "${uninst:0:24}" \
            "$(list_format_size "${APP_SIZES_KB[i]}")"
    done

    printf '\n%d application(s)  |  Remove with: mo uninstall <UNINSTALL NAME>\n\n' "$total"
}

list_output_json() {
    local total=${#APP_PATHS[@]}
    if ((total == 0)); then
        printf '[]\n'
        return 0
    fi

    printf '[\n'
    local i
    for ((i = 0; i < total; i++)); do
        printf '  {\n'
        printf '    "name": "%s",\n' "$(list_json_escape "${APP_NAMES[i]}")"
        printf '    "bundle_id": "%s",\n' "$(list_json_escape "${APP_BUNDLE_IDS[i]}")"
        printf '    "source": "%s",\n' "${APP_SOURCES[i]}"
        printf '    "uninstall_name": "%s",\n' "$(list_json_escape "${APP_UNINSTALL[i]}")"
        printf '    "path": "%s",\n' "$(list_json_escape "${APP_PATHS[i]}")"
        printf '    "size_kb": %s,\n' "${APP_SIZES_KB[i]:-0}"
        printf '    "size_human": "%s"\n' "$(list_format_size "${APP_SIZES_KB[i]}")"
        if ((i < total - 1)); then
            printf '  },\n'
        else
            printf '  }\n'
        fi
    done
    printf ']\n'
}

main() {
    parse_list_args "$@"

    # Auto-switch to JSON when stdout is not a TTY (matches `mo status`).
    if [[ ! -t 1 && "$OUTPUT_FORMAT" == "text" ]]; then
        OUTPUT_FORMAT="json"
    fi

    # Progress UI goes to stderr so it never contaminates JSON on stdout.
    local show_spinner=0
    if [[ "$OUTPUT_FORMAT" == "text" && -t 2 ]]; then
        show_spinner=1
    fi

    if [[ $show_spinner -eq 1 ]]; then
        start_inline_spinner "Scanning installed applications..."
    fi

    list_scan_all
    list_sort_apps

    if [[ $show_spinner -eq 1 ]]; then
        stop_inline_spinner
    fi

    case "$OUTPUT_FORMAT" in
        json) list_output_json ;;
        text | *) list_output_text ;;
    esac
}

# Only run main when not being sourced by the test harness.
if [[ "${MOLE_TEST_MODE:-0}" != "1" ]]; then
    main "$@"
fi
