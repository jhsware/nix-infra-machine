#!/usr/bin/env bash
# Shared helper functions for nix-infra-machine tests

# ============================================================================
# Colors for Test Output
# ============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================================================
# Utility Functions
# ============================================================================

appendWithLineBreak() {
  if [ -z "$1" ]; then
    printf '%s' "$2"
  else
    printf '%s\n%s' "$1" "$2"
  fi
}

cmd() {
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$1" "$2"
}

# Get command output with node prefix stripped and whitespace trimmed
# Use for single values that need arithmetic or exact comparison
# Example: count=$(cmd_value "$node" "pgrep -c redis-server || echo 0")
cmd_value() {
  local node="$1"
  local command="$2"
  local output
  output=$(cmd "$node" "$command")
  # Strip "nodename: " prefix and trim whitespace
  echo "$output" | sed "s/^${node}: //" | tr -d '[:space:]'
}

# Get command output with node prefix stripped but preserving structure
# Use for multi-line output or when whitespace matters
# Example: config=$(cmd_clean "$node" "cat /etc/config")
cmd_clean() {
  local node="$1"
  local command="$2"
  local output
  output=$(cmd "$node" "$command")
  # Strip "nodename: " prefix from each line
  echo "$output" | sed "s/^${node}: //"
}


printTime() {
  local _start=$1; local _end=$2; local _secs=$((_end-_start))
  printf '%02dh:%02dm:%02ds' $((_secs/3600)) $((_secs%3600/60)) $((_secs%60))
}

# ============================================================================
# Common Commands (used by run-tests.sh command parsing)
# ============================================================================

if [ "$CMD" = "pull" ]; then
  git -C "$WORK_DIR" pull
  exit 0
fi

if [ "$CMD" = "ssh" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 ssh --env=$ENV [node]"
    exit 1
  fi
  HCLOUD_TOKEN=$HCLOUD_TOKEN hcloud server ssh $REST -i "$WORK_DIR/ssh/$SSH_KEY"
  exit 0
fi

if [ "$CMD" = "cmd" ]; then
  if [ -z "$TARGET" ] || [ -z "$REST" ]; then
    echo "Usage: $0 cmd --env=$ENV --target=[node] [cmd goes here]"
    exit 1
  fi
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" "$REST"
  exit 0
fi

if [ "$CMD" = "action" ]; then
  if [ -z "$TARGET" ] || [ -z "$REST" ]; then
    echo "Usage: $0 action --env=$ENV --target=[node] [module] [cmd]"
    exit 1
  fi
  
  read -r module action_cmd <<< "$REST"
  $NIX_INFRA fleet action -d "$WORK_DIR" --target="$TARGET" --app-module="$module" \
    --cmd="$action_cmd"
  exit 0
fi

# ============================================================================
# Health Check Functions
# ============================================================================

checkNixos() {
  echo "Checking NixOS..."
  local NODES="$1"
  local node
  local _nixos_fail=""

  for node in $NODES; do
    local output=$(cmd "$node" "uname -a" 2>&1)
    local result="$output"
    if [[ "$result" == *"NixOS"* ]]; then
      echo "  ✓ nixos: ok ($node)"
    else
      echo "  ✗ nixos: fail ($node)"
      if [ -n "$output" ] && [[ "$output" == ERROR:* ]]; then
        echo "    $output"
      fi
      _nixos_fail="true"
    fi
  done

  if [ -n "$_nixos_fail" ]; then
    return 1
  fi
}

checkPodman() {
  echo "Checking Podman..."
  local NODES="$1"
  local node
  local _failed=""

  for node in $NODES; do
    local output=$(cmd "$node" "podman --version" 2>&1)
    local result="$output"
    if [[ "$result" == *"podman version"* ]]; then
      echo "  ✓ podman: ok ($node)"
    else
      echo "  ✗ podman: not installed or not running ($node)"
      if [ -n "$output" ] && [[ "$output" == ERROR:* ]]; then
        echo "    $output"
      fi
      _failed="yes"
    fi
  done

  if [ -n "$_failed" ]; then
    return 1
  fi
}

checkService() {
  local NODE="$1"
  local SERVICE="$2"
  local output=$(cmd "$NODE" "systemctl is-active $SERVICE" 2>&1)
  local result="$output"
  if [[ "$result" == *"active"* ]]; then
    echo "  ✓ $SERVICE: active ($NODE)"
    return 0
  else
    echo "  ✗ $SERVICE: inactive ($NODE)"
    if [ -n "$output" ] && [[ "$output" == ERROR:* ]]; then
      echo "    $output"
    fi
    return 1
  fi
}

checkServiceOnNodes() {
  echo "Checking service: $2"
  local NODES="$1"
  local SERVICE="$2"
  local node
  local _failed=""

  for node in $NODES; do
    if ! checkService "$node" "$SERVICE"; then
      _failed="yes"
    fi
  done

  if [ -n "$_failed" ]; then
    return 1
  fi
}

checkHttpEndpoint() {
  local NODE="$1"
  local URL="$2"
  local EXPECTED="$3"
  
  local output=$(cmd "$NODE" "curl -s --max-time 5 '$URL'" 2>&1)
  local result="$output"
  if [[ "$result" == *"$EXPECTED"* ]]; then
    echo "  ✓ HTTP $URL: ok ($NODE)"
    return 0
  else
    echo "  ✗ HTTP $URL: expected '$EXPECTED' ($NODE)"
    if [ -n "$output" ] && [[ "$output" == ERROR:* ]]; then
      echo "    $output"
    fi
    return 1
  fi
}

checkTcpPort() {
  local NODE="$1"
  local HOST="$2"
  local PORT="$3"
  
  local output=$(cmd "$NODE" "nc -zv $HOST $PORT 2>&1")
  local result="$output"
  if [[ "$result" == *"succeeded"* ]] || [[ "$result" == *"open"* ]] || [[ "$result" == *"Connected"* ]]; then
    echo "  ✓ TCP $HOST:$PORT: open ($NODE)"
    return 0
  else
    echo "  ✗ TCP $HOST:$PORT: closed ($NODE)"
    if [ -n "$output" ] && [[ "$output" == ERROR:* ]]; then
      echo "    $output"
    fi
    return 1
  fi
}

# ============================================================================
# Fleet Test Function
# ============================================================================

testFleet() {
  local NODES="$1"
  echo "=========================================="
  echo "Running Fleet Health Checks"
  echo "=========================================="
  
  local _failed=""
  
  if ! checkNixos "$NODES"; then
    _failed="yes"
  fi
  
  echo "=========================================="
  if [ -n "$_failed" ]; then
    echo "Health checks: FAILED"
    return 1
  else
    echo "Health checks: PASSED"
    return 0
  fi
}

# ============================================================================
# Container/Pod Test Helpers
# ============================================================================

waitForContainer() {
  local NODE="$1"
  local CONTAINER="$2"
  local TIMEOUT="${3:-60}"
  
  echo "Waiting for container $CONTAINER on $NODE (timeout: ${TIMEOUT}s)..."
  local elapsed=0
  local last_output=""
  while [ $elapsed -lt $TIMEOUT ]; do
    last_output=$(cmd "$NODE" "podman ps --filter name=$CONTAINER --format '{{.Status}}'" 2>&1)
    local status="$last_output"
    if [[ "$status" == *"Up"* ]]; then
      echo "  ✓ Container $CONTAINER is running"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  
  echo "  ✗ Container $CONTAINER did not start within ${TIMEOUT}s"
  if [ -n "$last_output" ] && [[ "$last_output" == ERROR:* ]]; then
    echo "    $last_output"
  fi
  return 1
}

waitForService() {
  local NODE="$1"
  local SERVICE="$2"
  local TIMEOUT="${3:-60}"
  
  echo "Waiting for service $SERVICE on $NODE (timeout: ${TIMEOUT}s)..."
  local elapsed=0
  local last_output=""
  while [ $elapsed -lt $TIMEOUT ]; do
    last_output=$(cmd "$NODE" "systemctl is-active $SERVICE" 2>&1)
    local status="$last_output"
    if [[ "$status" == *"active"* ]]; then
      echo "  ✓ Service $SERVICE is active"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  
  echo "  ✗ Service $SERVICE did not become active within ${TIMEOUT}s"
  if [ -n "$last_output" ] && [[ "$last_output" == ERROR:* ]]; then
    echo "    $last_output"
  fi
  return 1
}

getContainerLogs() {
  local NODE="$1"
  local CONTAINER="$2"
  local LINES="${3:-50}"
  
  echo "--- Container logs for $CONTAINER on $NODE ---"
  cmd "$NODE" "podman logs --tail $LINES $CONTAINER" 2>&1
  echo "--- End of logs ---"
}

getServiceLogs() {
  local NODE="$1"
  local SERVICE="$2"
  local LINES="${3:-50}"
  
  echo "--- Service logs for $SERVICE on $NODE ---"
  cmd "$NODE" "journalctl -n $LINES -u $SERVICE" 2>&1
  echo "--- End of logs ---"
}

# ============================================================================
# Info output
# ============================================================================

# Print info line (not pass/fail)
# Usage: print_info "label" "value"
print_info() {
  local label="$1"
  local value="$2"
  
  echo -e "  ${GREEN}✓${NC} $label: $value [info]"
}

# Print cleanup success
# Usage: print_cleanup "label"
print_cleanup() {
  local label="$1"
  
  echo -e "  ${GREEN}✓${NC} $label [pass]"
}