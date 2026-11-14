#!/usr/bin/env bash

set -uo pipefail
umask 077

# ==========================================
# Global Default Configuration
# ==========================================
# Leave empty to load from environment variable or ENV_FILE (recommended for Git)
HARDCODED_PASSWORD=""
ENV_FILE="$HOME/.oc-tailnet.env"

# Runtime state (pid/dir/log) is stored under XDG_RUNTIME_DIR when available.
RUNTIME_DIR=""

# ANSI Color Codes
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[0;33m'
COLOR_GREEN='\033[0;32m'
COLOR_CYAN='\033[0;96m'
COLOR_RESET='\033[0m'

# ==========================================
# Logging Helper Functions
# ==========================================

print_info() {
	printf "${COLOR_GREEN}[INFO] %s${COLOR_RESET}\n" "$1"
}

print_warn() {
	printf "${COLOR_YELLOW}[WARN] %s${COLOR_RESET}\n" "$1" >&2
}

print_error() {
	printf "${COLOR_RED}[ERROR] %s${COLOR_RESET}\n" "$1" >&2
}

print_debug() {
	printf "${COLOR_CYAN}[DEBUG] %s${COLOR_RESET}\n" "$1" >&2
}

# ==========================================
# System Environment & Dependency Checks
# ==========================================

# 1. Check Tailscale installation and connection status, return IPv4 address
get_tailscale_ip() {
	if ! command -v tailscale >/dev/null 2>&1; then
		print_error "Tailscale is not installed. Please install Tailscale first."
		return 1
	fi

	local ts_ip
	ts_ip=$(tailscale ip -4 2>/dev/null | awk 'NR==1{print; exit}')

	if [ -z "$ts_ip" ]; then
		print_error "Failed to get Tailscale IP. Please ensure Tailscale is running and logged in (tailscale up)."
		return 1
	fi

	echo "$ts_ip"
}

# Check whether an IPv4 address is assigned to a local interface
ts_ip_is_local() {
	local ip="$1"
	local addrs
	local _idx _name _family addr _rest

	if ! command -v ip >/dev/null 2>&1; then
		print_warn "'ip' command not found; skipping local-address check."
		return 0
	fi

	addrs=$(ip -4 -o addr show 2>/dev/null)
	while read -r _idx _name _family addr _rest; do
		[ -n "${addr:-}" ] || continue
		if [ "${addr%%/*}" = "$ip" ]; then
			return 0
		fi
	done <<< "$addrs"

	return 1
}

# 2. Check if network inspection tools (ss or netstat) are available
check_network_tools() {
	if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
		print_error "Neither 'ss' nor 'netstat' is installed. Cannot verify port availability."
		print_error "Please install one of them (e.g., sudo apt update && sudo apt install -y iproute2 net-tools)."
		exit 1
	fi
}

# 3. Check if OpenCode CLI is installed
check_opencode_installed() {
	if ! command -v opencode >/dev/null 2>&1; then
		print_error "'opencode' command not found. Please ensure it is installed and in your PATH."
		exit 1
	fi
}

# ==========================================
# Helper Functions
# ==========================================

# Load ENV_FILE into the current shell without overriding variables that were
# already exported by the caller. Sourcing here (instead of inside a subshell)
# keeps settings such as OPENCODE_BIND_HOST available to cmd_start.
load_env_file() {
	[ -f "$ENV_FILE" ] || return 0

	local perms=""
	perms=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || true)
	if [ -n "$perms" ] && (( 8#$perms & 077 )); then
		print_warn "ENV file $ENV_FILE is accessible by group/others (mode $perms). Run: chmod 600 $ENV_FILE"
	fi

	local prev_pw="${OPENCODE_SERVER_PASSWORD:-}"
	local prev_host="${OPENCODE_BIND_HOST:-}"

	set -a
	# shellcheck disable=SC1090
	source "$ENV_FILE"
	set +a

	# Shell environment takes precedence over the config file.
	if [ -n "$prev_pw" ]; then
		OPENCODE_SERVER_PASSWORD="$prev_pw"
	fi
	if [ -n "$prev_host" ]; then
		OPENCODE_BIND_HOST="$prev_host"
	fi
}

# Resolve server password with priority:
# 1. HARDCODED_PASSWORD in script
# 2. Current shell environment variable OPENCODE_SERVER_PASSWORD
# 3. Sourced from ENV_FILE (~/.oc-tailnet.env)
# 4. Abort if still empty
# Sets RESOLVED_PASSWORD and PASSWORD_SOURCE for the caller.
resolve_password() {
	local shell_pw="${OPENCODE_SERVER_PASSWORD:-}"

	load_env_file

	RESOLVED_PASSWORD=""
	PASSWORD_SOURCE=""

	if [ -n "$HARDCODED_PASSWORD" ]; then
		RESOLVED_PASSWORD="$HARDCODED_PASSWORD"
		PASSWORD_SOURCE="hardcoded"
	elif [ -n "$shell_pw" ]; then
		RESOLVED_PASSWORD="$shell_pw"
		PASSWORD_SOURCE="shell_env"
	elif [ -n "${OPENCODE_SERVER_PASSWORD:-}" ]; then
		RESOLVED_PASSWORD="$OPENCODE_SERVER_PASSWORD"
		PASSWORD_SOURCE="env_file"
	fi

	if [ -z "$RESOLVED_PASSWORD" ]; then
		print_error "OPENCODE_SERVER_PASSWORD is not set. Refusing to start without a password."
		echo "" >&2
		echo "Please configure a password using one of the following methods (in priority order):" >&2
		echo "" >&2
		echo "  1. [Script] Set HARDCODED_PASSWORD directly inside $0:" >&2
		echo "     HARDCODED_PASSWORD=\"your_secure_password\"" >&2
		echo "" >&2
		echo "  2. [Shell] Pass or export the environment variable:" >&2
		echo "     OPENCODE_SERVER_PASSWORD=\"your_secure_password\" $0 start <dir> <port>" >&2
		echo "" >&2
		echo "  3. [Config File - Recommended] Create $ENV_FILE:" >&2
		echo "     echo 'OPENCODE_SERVER_PASSWORD=\"your_secure_password\"' > $ENV_FILE && chmod 600 $ENV_FILE" >&2
		echo "" >&2
		return 1
	fi

	return 0
}

# Validate that a port is an integer within 1-65535
validate_port() {
	local port="$1"

	if ! [[ "$port" =~ ^[0-9]+$ ]]; then
		print_error "Invalid port: $port (must be an integer between 1 and 65535)."
		return 1
	fi

	if (( 10#$port < 1 || 10#$port > 65535 )); then
		print_error "Invalid port: $port (must be between 1 and 65535)."
		return 1
	fi

	return 0
}

# Resolve and create the runtime state directory
init_runtime_dir() {
	if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then
		RUNTIME_DIR="$XDG_RUNTIME_DIR/opencode-tailnet"
	else
		RUNTIME_DIR="/tmp/opencode-tailnet-$(id -u)"
	fi

	if ! mkdir -p "$RUNTIME_DIR"; then
		print_error "Failed to create runtime directory: $RUNTIME_DIR"
		exit 1
	fi
	chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
}

# Serialize start/stop operations when flock is available
acquire_runtime_lock() {
	if ! command -v flock >/dev/null 2>&1; then
		return 0
	fi

	if ! exec 9>"$RUNTIME_DIR/.lock"; then
		print_error "Failed to open lock file in $RUNTIME_DIR"
		exit 1
	fi

	if ! flock -n 9; then
		print_error "Another start/stop operation is already in progress."
		exit 1
	fi
}

pid_file() {
	printf '%s/%s.pid' "$RUNTIME_DIR" "$1"
}

dir_file() {
	printf '%s/%s.dir' "$RUNTIME_DIR" "$1"
}

log_file() {
	printf '%s/%s.log' "$RUNTIME_DIR" "$1"
}

legacy_dir_file() {
	printf '/tmp/opencode-%s.dir' "$1"
}

# Check if a PID is an OpenCode server process owned by the current user
is_opencode_serve_pid() {
	local pid="$1"
	local cmdline="/proc/$pid/cmdline"
	local -a argv=()
	local i
	local has_serve=0

	[ -r "$cmdline" ] || return 1
	[ -O "$cmdline" ] || return 1
	mapfile -d '' -t argv < "$cmdline" 2>/dev/null || return 1
	[ "${#argv[@]}" -ge 2 ] || return 1
	[ "$(basename -- "${argv[0]}")" = "opencode" ] || return 1

	for ((i = 1; i < ${#argv[@]}; i++)); do
		if [ "${argv[i]}" = "serve" ]; then
			has_serve=1
			break
		fi
	done

	[ "$has_serve" -eq 1 ]
}

# Extract the --port value from a process command line
get_pid_port() {
	local pid="$1"
	local cmdline="/proc/$pid/cmdline"
	local -a argv=()
	local i

	[ -r "$cmdline" ] || return 1
	mapfile -d '' -t argv < "$cmdline" 2>/dev/null || return 1

	for ((i = 0; i < ${#argv[@]}; i++)); do
		case "${argv[i]}" in
			--port)
				if [ $((i + 1)) -lt "${#argv[@]}" ]; then
					printf '%s\n' "${argv[i + 1]}"
					return 0
				fi
				;;
			--port=*)
				printf '%s\n' "${argv[i]#--port=}"
				return 0
				;;
		esac
	done

	return 1
}

# Find all OpenCode server PIDs listening on an exact port
find_server_pids_by_port() {
	local port="$1"
	local cmdline pid found_port

	for cmdline in /proc/[0-9]*/cmdline; do
		[ -e "$cmdline" ] || continue
		pid="${cmdline#/proc/}"
		pid="${pid%/cmdline}"

		is_opencode_serve_pid "$pid" || continue
		found_port=$(get_pid_port "$pid" 2>/dev/null) || continue

		if [ "$found_port" = "$port" ]; then
			printf '%s\n' "$pid"
		fi
	done
}

# List all OpenCode server PIDs owned by the current user
all_server_pids() {
	local cmdline pid

	for cmdline in /proc/[0-9]*/cmdline; do
		[ -e "$cmdline" ] || continue
		pid="${cmdline#/proc/}"
		pid="${pid%/cmdline}"

		if is_opencode_serve_pid "$pid"; then
			printf '%s\n' "$pid"
		fi
	done
}

# Check if a specific port is currently listening (returns 0 if in use, 1 if free)
is_port_listening() {
	local port="$1"
	local output=""

	if command -v ss >/dev/null 2>&1; then
		output=$(ss -H -ltn "sport = :$port" 2>/dev/null || true)
		[ -n "$output" ]
		return
	fi

	if command -v netstat >/dev/null 2>&1; then
		output=$(netstat -ltn 2>/dev/null || true)
		case "$output" in
			*":$port "*) return 0 ;;
			*) return 1 ;;
		esac
	fi

	return 2
}

# Check if an OpenCode server is already running for the target directory
check_dir_not_running() {
	local target_dir="$1"
	local file port recorded_dir pids

	for file in "$RUNTIME_DIR"/*.dir; do
		[ -f "$file" ] || continue

		port=$(basename "$file" .dir)
		recorded_dir=$(cat "$file" 2>/dev/null || true)
		pids=$(find_server_pids_by_port "$port")

		if [ -n "$pids" ]; then
			if [ "$recorded_dir" = "$target_dir" ]; then
				print_warn "An OpenCode server is already running for directory: $target_dir (Port: $port)."
				return 1
			fi
		else
			# Clean up stale state if the process died unexpectedly
			rm -f "$file" "$(pid_file "$port")"
		fi
	done

	for file in /tmp/opencode-*.dir; do
		[ -f "$file" ] || continue
		[ -O "$file" ] || continue

		port=$(basename "$file" .dir)
		port="${port#opencode-}"
		[[ "$port" =~ ^[0-9]+$ ]] || continue

		recorded_dir=$(cat "$file" 2>/dev/null || true)
		pids=$(find_server_pids_by_port "$port")

		if [ -n "$pids" ]; then
			if [ "$recorded_dir" = "$target_dir" ]; then
				print_warn "An OpenCode server is already running for directory: $target_dir (Port: $port)."
				return 1
			fi
		else
			rm -f "$file"
		fi
	done

	return 0
}

# Print CLI usage instructions
print_usage() {
	echo "Usage: $0 <command> [arguments]"
	echo ""
	echo "Commands:"
	echo "  start <project_dir> <port>   Start background OpenCode server in target directory"
	echo "  status                       Show status of all running OpenCode servers"
	echo "  stop <port>                  Stop the OpenCode server running on the specified port"
	echo "  help                         Show this help"
	echo ""
	echo "Environment:"
	echo "  OPENCODE_SERVER_PASSWORD     Server password (or set it in $ENV_FILE)"
	echo "  OPENCODE_BIND_HOST           Override listen address (default: Tailscale IPv4)"
	echo ""
	echo "Examples:"
	echo "  $0 start ~/projects/project-a 4096"
	echo "  $0 status"
	echo "  $0 stop 4096"
}

# ==========================================
# Core Subcommands (start / status / stop)
# ==========================================

cmd_start() {
	local raw_dir="${1:-}"
	local port="${2:-}"

	if [ -z "$raw_dir" ] || [ -z "$port" ]; then
		print_error "'start' requires <project_dir> and <port>."
		print_info "Example: $0 start ~/projects/project-a 4096"
		exit 1
	fi

	validate_port "$port" || exit 1

	if [ ! -d "$raw_dir" ]; then
		print_error "Directory not found: $raw_dir"
		exit 1
	fi

	local dir
	dir=$(realpath -- "$raw_dir") || {
		print_error "Failed to resolve directory: $raw_dir"
		exit 1
	}

	init_runtime_dir
	acquire_runtime_lock

	check_network_tools
	check_opencode_installed

	# Ensure neither the directory nor the port is already occupied
	if ! check_dir_not_running "$dir"; then
		exit 1
	fi

	if is_port_listening "$port"; then
		print_warn "Port $port is already in use."
		exit 1
	fi

	# Resolve password strictly before starting
	resolve_password || exit 1
	local password="$RESOLVED_PASSWORD"

	local ts_ip
	ts_ip=$(get_tailscale_ip) || exit 1

	local bind_host="${OPENCODE_BIND_HOST:-$ts_ip}"

	if [ -z "${OPENCODE_BIND_HOST:-}" ]; then
		if ! ts_ip_is_local "$ts_ip"; then
			print_error "Tailscale IP $ts_ip is not assigned to a local interface."
			echo "" >&2
			echo "This usually means Tailscale runs on Windows while OpenCode runs inside WSL." >&2
			echo "Choose one of the following:" >&2
			echo "  1. Install and run Tailscale inside WSL (recommended), or" >&2
			echo "  2. Set OPENCODE_BIND_HOST=0.0.0.0 in $ENV_FILE and restrict access via firewall/ACL." >&2
			exit 1
		fi
	elif [ "$bind_host" = "0.0.0.0" ]; then
		print_warn "Binding to 0.0.0.0 exposes the server on all interfaces. Ensure firewall/Tailscale ACL protection."
	fi

	local cmd_preview
	cmd_preview=$(printf 'cd %q && nohup env OPENCODE_SERVER_PASSWORD=*** opencode serve --hostname %q --port %q' \
		"$dir" "$bind_host" "$port")
	print_debug "Executing: $cmd_preview"

	local log
	log="$(log_file "$port")"

	local pid
	(
		cd "$dir" || exit 1
		exec nohup env OPENCODE_SERVER_PASSWORD="$password" opencode serve \
			--hostname "$bind_host" --port "$port"
	) 9>&- >"$log" 2>&1 &
	pid=$!

	local i ready=0
	for i in $(seq 1 50); do
		if ! kill -0 "$pid" 2>/dev/null; then
			break
		fi
		if is_port_listening "$port"; then
			ready=1
			break
		fi
		sleep 0.2
	done

	if [ "$ready" -ne 1 ] || ! kill -0 "$pid" 2>/dev/null; then
		print_error "OpenCode server failed to start on port $port."
		if [ -s "$log" ]; then
			echo "--- log tail ($log) ---" >&2
			tail -n 20 "$log" >&2
			echo "-----------------------" >&2
		fi
		kill "$pid" 2>/dev/null || true
		sleep 0.2
		kill -9 "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
		rm -f "$(pid_file "$port")" "$(dir_file "$port")"
		exit 1
	fi

	printf '%s\n' "$pid" > "$(pid_file "$port")"
	printf '%s\n' "$dir" > "$(dir_file "$port")"
	chmod 600 "$(pid_file "$port")" "$(dir_file "$port")" "$log" 2>/dev/null || true

	print_info "OpenCode server started in background ($dir)"
	print_info "Listening on: $bind_host:$port"
	print_info "Remote attach command:"
	echo ""
	echo "  opencode attach http://$ts_ip:$port"
	echo ""
	echo "  Auth: provide OPENCODE_SERVER_PASSWORD or use -p <password>."
	if [ "$PASSWORD_SOURCE" = "env_file" ]; then
		echo "  (same host, password from $ENV_FILE) set -a; . \"$ENV_FILE\"; set +a"
	fi
	echo ""
}

cmd_status() {
	init_runtime_dir

	local ts_ip=""
	ts_ip=$(get_tailscale_ip 2>/dev/null) || ts_ip=""

	if [ -n "$ts_ip" ]; then
		print_info "OpenCode Remote Server Status (Tailscale IP: $ts_ip)"
	else
		print_warn "Tailscale IP unavailable; showing local status."
		print_info "OpenCode Remote Server Status"
	fi

	local pids
	pids=$(all_server_pids)

	if [ -z "$pids" ]; then
		local stale
		for stale in "$RUNTIME_DIR"/*.pid; do
			[ -f "$stale" ] || continue
			rm -f "$stale" "${stale%.pid}.dir"
		done
		print_warn "No running OpenCode servers found."
		return 0
	fi

	local pid port dir url found=0
	while read -r pid; do
		[ -n "$pid" ] || continue

		port=$(get_pid_port "$pid" 2>/dev/null) || continue
		[ -n "$port" ] || continue

		found=1
		dir=""
		if [ -f "$(dir_file "$port")" ]; then
			dir=$(cat "$(dir_file "$port")" 2>/dev/null || true)
		fi
		if [ -z "$dir" ] && [ -f "$(legacy_dir_file "$port")" ]; then
			dir=$(cat "$(legacy_dir_file "$port")" 2>/dev/null || true)
		fi
		if [ -z "$dir" ]; then
			dir=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
		fi
		[ -n "$dir" ] || dir="Unknown directory"

		url="http://${ts_ip:-<tailscale-ip>}:$port"
		print_info "[RUNNING] Port: $port | PID: $pid | Dir: $dir | URL: $url"

		# Refresh state files for servers started by older versions of this script
		printf '%s\n' "$pid" > "$(pid_file "$port")"
		printf '%s\n' "$dir" > "$(dir_file "$port")"
		chmod 600 "$(pid_file "$port")" "$(dir_file "$port")" 2>/dev/null || true
	done <<< "$pids"

	local stale_port
	for stale in "$RUNTIME_DIR"/*.pid; do
		[ -f "$stale" ] || continue
		stale_port=$(basename "$stale" .pid)
		if [ -z "$(find_server_pids_by_port "$stale_port")" ]; then
			rm -f "$stale" "$(dir_file "$stale_port")"
		fi
	done

	if [ "$found" -eq 0 ]; then
		print_warn "No OpenCode servers bound to a specific port were detected."
	fi
}

cmd_stop() {
	local port="${1:-}"

	if [ -z "$port" ]; then
		print_error "'stop' requires <port>."
		print_info "Example: $0 stop 4096"
		exit 1
	fi

	validate_port "$port" || exit 1

	init_runtime_dir
	acquire_runtime_lock

	local pids
	pids=$(find_server_pids_by_port "$port")

	if [ -z "$pids" ]; then
		rm -f "$(pid_file "$port")" "$(dir_file "$port")"
		print_warn "No running OpenCode server found on port $port."
		exit 1
	fi

	local pid
	while read -r pid; do
		[ -n "$pid" ] || continue
		kill "$pid" 2>/dev/null || true
	done <<< "$pids"

	local i alive=""
	for i in $(seq 1 25); do
		alive=""
		while read -r pid; do
			[ -n "$pid" ] || continue
			if kill -0 "$pid" 2>/dev/null; then
				alive+="$pid "
			fi
		done <<< "$pids"
		[ -z "$alive" ] && break
		sleep 0.2
	done

	if [ -n "$alive" ]; then
		while read -r pid; do
			[ -n "$pid" ] || continue
			kill -9 "$pid" 2>/dev/null || true
		done <<< "$pids"
		sleep 0.2
	fi

	if is_port_listening "$port"; then
		print_error "Port $port is still listening after stopping PIDs: $(printf '%s' "$pids" | tr '\n' ' ')"
		exit 1
	fi

	rm -f "$(pid_file "$port")" "$(dir_file "$port")" \
		"$(legacy_dir_file "$port")" "/tmp/opencode-$port.log"

	print_info "OpenCode server on port $port (PID(s): $(printf '%s' "$pids" | tr '\n' ' ')) has been stopped."
}

# ==========================================
# Main Entry Point
# ==========================================

main() {
	local action="${1:-}"
	if [ $# -gt 0 ]; then
		shift
	fi

	case "$action" in
		start)
			cmd_start "$@"
			;;
		status)
			cmd_status
			;;
		stop)
			cmd_stop "$@"
			;;
		help|-h|--help)
			print_usage
			exit 0
			;;
		*)
			print_usage
			exit 1
			;;
	esac
}

main "$@"
