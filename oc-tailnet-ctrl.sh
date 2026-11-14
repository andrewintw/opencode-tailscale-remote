#!/usr/bin/env bash

# ==========================================
# Global Default Configuration
# ==========================================
# Leave empty to load from environment variable or ENV_FILE (recommended for Git)
HARDCODED_PASSWORD=""
ENV_FILE="$HOME/.oc-tailnet.env"

# ANSI Color Codes
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[0;33m'
COLOR_GREEN='\033[0;32m'
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

# ==========================================
# System Environment & Dependency Checks
# ==========================================

# 1. Check Tailscale installation and connection status, return IPv4 address
get_tailscale_ip() {
	if ! command -v tailscale >/dev/null 2>&1; then
		print_error "Tailscale is not installed. Please install Tailscale first."
		exit 1
	fi

	local ts_ip
	ts_ip=$(tailscale ip -4 2>/dev/null | head -n 1)

	if [ -z "$ts_ip" ]; then
		print_error "Failed to get Tailscale IP. Please ensure Tailscale is running and logged in (tailscale up)."
		exit 1
	fi

	echo "$ts_ip"
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

# Resolve server password with priority:
# 1. HARDCODED_PASSWORD in script
# 2. Current shell environment variable OPENCODE_SERVER_PASSWORD
# 3. Sourced from ENV_FILE (~/.oc-tailnet.env)
# 4. Abort if still empty
resolve_password() {
	local resolved_pw=""

	if [ -n "$HARDCODED_PASSWORD" ]; then
		resolved_pw="$HARDCODED_PASSWORD"
	elif [ -n "$OPENCODE_SERVER_PASSWORD" ]; then
		resolved_pw="$OPENCODE_SERVER_PASSWORD"
	elif [ -f "$ENV_FILE" ]; then
		# Load variables from dotenv file
		set -a
		# shellcheck disable=SC1090
		source "$ENV_FILE"
		set +a
		resolved_pw="$OPENCODE_SERVER_PASSWORD"
	fi

	if [ -z "$resolved_pw" ]; then
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
		exit 1
	fi

	echo "$resolved_pw"
}

# Check if a specific port is currently listening (returns 0 if in use, 1 if free)
is_port_listening() {
	local port="$1"

	if command -v ss >/dev/null 2>&1; then
		ss -tuln | grep -q ":$port "
	elif command -v netstat >/dev/null 2>&1; then
		netstat -tuln | grep -q ":$port "
	fi
}

# Check if an OpenCode server is already running for the target directory
check_dir_not_running() {
	local target_dir="$1"
	local dir_file

	for dir_file in /tmp/opencode-*.dir; do
		[ -f "$dir_file" ] || continue

		local recorded_dir
		recorded_dir=$(cat "$dir_file")

		if [ "$recorded_dir" = "$target_dir" ]; then
			local existing_port
			existing_port=$(basename "$dir_file" | sed -E 's/^opencode-([0-9]+)\.dir$/\1/')

			# Verify the process on that port is actually still alive
			if pgrep -f "opencode serve.*--port $existing_port" >/dev/null 2>&1; then
				print_warn "An OpenCode server is already running for directory: $target_dir (Port: $existing_port)."
				exit 1
			else
				# Clean up stale .dir file if process died unexpectedly
				rm -f "$dir_file"
			fi
		fi
	done
}

# Print CLI usage instructions
print_usage() {
	echo "Usage: $0 <command> [arguments]"
	echo ""
	echo "Commands:"
	echo "  start <project_dir> <port>   Start background OpenCode server in target directory"
	echo "  status                       Show status of all running OpenCode servers"
	echo "  stop <port>                  Stop the OpenCode server running on the specified port"
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
	local raw_dir="$1"
	local port="$2"

	if [ -z "$raw_dir" ] || [ -z "$port" ]; then
		print_error "'start' requires <project_dir> and <port>."
		print_info "Example: $0 start ~/projects/project-a 4096"
		exit 1
	fi

	if [ ! -d "$raw_dir" ]; then
		print_error "Directory not found: $raw_dir"
		exit 1
	fi

	local dir
	dir=$(realpath "$raw_dir")

	# Ensure neither the directory nor the port is already occupied
	check_dir_not_running "$dir"

	if is_port_listening "$port"; then
		print_warn "Port $port is already in use."
		exit 1
	fi

	# Resolve password strictly before starting
	local password
	password=$(resolve_password) || exit 1

	local ts_ip
	ts_ip=$(get_tailscale_ip) || exit 1

	# Record target directory for status lookup and start background server
	echo "$dir" > "/tmp/opencode-$port.dir"
	(
		cd "$dir" || exit 1
		OPENCODE_SERVER_PASSWORD="$password" nohup opencode serve --hostname 0.0.0.0 --port "$port" > "/tmp/opencode-$port.log" 2>&1 &
	)

	sleep 1

	print_info "OpenCode server started in background ($dir)"
	print_info "Remote attach command:"
	echo ""
	echo "  OPENCODE_SERVER_PASSWORD=$password opencode attach http://$ts_ip:$port"
	echo ""
}

cmd_status() {
	local ts_ip
	ts_ip=$(get_tailscale_ip) || exit 1

	print_info "OpenCode Remote Server Status (Tailscale IP: $ts_ip)"

	local pids
	pids=$(pgrep -f "opencode serve")

	if [ -z "$pids" ]; then
		print_warn "No running OpenCode servers found."
		return 0
	fi

	local found=0
	while read -r pid; do
		local cmdline
		cmdline=$(ps -p "$pid" -o args=)
		local port
		port=$(echo "$cmdline" | grep -oE -- '--port [0-9]+' | awk '{print $2}')

		if [ -n "$port" ]; then
			found=1
			local dir="Unknown directory"
			[ -f "/tmp/opencode-$port.dir" ] && dir=$(cat "/tmp/opencode-$port.dir")

			print_info "[RUNNING] Port: $port | PID: $pid | Dir: $dir | URL: http://$ts_ip:$port"
		fi
	done <<< "$pids"

	if [ "$found" -eq 0 ]; then
		print_warn "No OpenCode servers bound to a specific port were detected."
	fi
}

cmd_stop() {
	local port="$1"

	if [ -z "$port" ]; then
		print_error "'stop' requires <port>."
		print_info "Example: $0 stop 4096"
		exit 1
	fi

	local pid
	pid=$(pgrep -f "opencode serve.*--port $port")

	if [ -z "$pid" ]; then
		print_warn "No running OpenCode server found on port $port."
		exit 1
	fi

	kill "$pid" 2>/dev/null
	sleep 1

	# Force kill if process is still alive
	if kill -0 "$pid" 2>/dev/null; then
		kill -9 "$pid" 2>/dev/null
	fi

	rm -f "/tmp/opencode-$port.dir"
	print_info "OpenCode server on port $port (PID: $pid) has been stopped."
}

# ==========================================
# Main Entry Point
# ==========================================
main() {
	# Phase 1: System environment and dependency checks
	local ts_ip
	ts_ip=$(get_tailscale_ip) || exit 1
	check_network_tools
	check_opencode_installed

	# Phase 2: Parse subcommand and dispatch
	local action="$1"
	shift

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
		*)
			print_usage
			exit 1
			;;
	esac
}

main "$@"
