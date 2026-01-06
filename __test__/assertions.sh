#!/usr/bin/env bash
# Assertion library for nix-infra-machine tests
# Provides reusable assertion functions with consistent output formatting
#
# All assertions follow this pattern:
#   assert_* "label" [args...]
#   Returns 0 on pass, 1 on fail
#   Prints colored pass/fail message
#
# Requires: Colors (GREEN, RED, YELLOW, NC) from shared.sh
# Requires: cmd, cmd_value, cmd_clean functions from shared.sh

# ============================================================================
# Service Assertions
# ============================================================================

# Check if a systemd service is active
# Usage: assert_service_active "$node" "service-name" ["optional label"]
assert_service_active() {
  local node="$1"
  local service="$2"
  local label="${3:-$service}"
  
  local status
  status=$(cmd_value "$node" "systemctl is-active $service")
  
  if [[ "$status" == "active" ]]; then
    echo -e "  ${GREEN}✓${NC} $label: active [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label: $status [fail]"
    return 1
  fi
}

# Check if a oneshot service completed successfully
# Usage: assert_service_completed "$node" "service-name" ["optional label"]
assert_service_completed() {
  local node="$1"
  local service="$2"
  local label="${3:-$service}"
  
  local status
  status=$(cmd_value "$node" "systemctl is-active $service 2>/dev/null || echo 'inactive'")
  
  if [[ "$status" == "inactive" ]]; then
    local exit_status
    exit_status=$(cmd_value "$node" "systemctl show -p ExecMainStatus $service | cut -d= -f2")
    if [[ "$exit_status" == "0" ]]; then
      echo -e "  ${GREEN}✓${NC} $label: completed successfully [pass]"
      return 0
    else
      echo -e "  ${RED}✗${NC} $label: failed (exit status: $exit_status) [fail]"
      return 1
    fi
  else
    echo -e "  ${GREEN}✓${NC} $label: $status [pass]"
    return 0
  fi
}

# Check if service SubState is running
# Usage: assert_service_running "$node" "service-name" ["optional label"]
assert_service_running() {
  local node="$1"
  local service="$2"
  local label="${3:-$service}"
  
  local state
  state=$(cmd_value "$node" "systemctl show -p SubState $service --value")
  
  if [[ "$state" == "running" ]]; then
    echo -e "  ${GREEN}✓${NC} $label: running [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label: $state [fail]"
    return 1
  fi
}

# ============================================================================
# Process Assertions
# ============================================================================

# Check if a process is running (using pgrep pattern)
# Usage: assert_process_running "$node" "pattern" "label"
assert_process_running() {
  local node="$1"
  local pattern="$2"
  local label="$3"
  
  local result
  result=$(cmd_clean "$node" "pgrep -a $pattern || echo ''")
  
  if [[ -n "$result" ]]; then
    echo -e "  ${GREEN}✓${NC} $label process running [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label process not running [fail]"
    return 1
  fi
}

# Check process count meets minimum
# Usage: assert_process_count "$node" "pattern" "min_count" "label"
assert_process_count() {
  local node="$1"
  local pattern="$2"
  local min_count="$3"
  local label="$4"
  
  local count
  count=$(cmd_value "$node" "pgrep -c $pattern || echo 0")
  
  if [[ "$count" -ge "$min_count" ]]; then
    echo -e "  ${GREEN}✓${NC} $count $label processes running [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} Expected $min_count $label processes, found $count [fail]"
    return 1
  fi
}

# ============================================================================
# Port Assertions
# ============================================================================

# Check if a port is listening
# Usage: assert_port_listening "$node" "port" ["label"]
assert_port_listening() {
  local node="$1"
  local port="$2"
  local label="${3:-Port $port}"
  
  local result
  result=$(cmd "$node" "ss -tlnp | grep :$port")
  
  if [[ "$result" == *":$port"* ]]; then
    echo -e "  ${GREEN}✓${NC} $label is listening [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label is not listening [fail]"
    return 1
  fi
}

# ============================================================================
# HTTP Assertions
# ============================================================================

# Check HTTP status code
# Usage: assert_http_status "$node" "url" "expected_codes" ["label"]
# expected_codes can be space-separated: "200 302 303"
assert_http_status() {
  local node="$1"
  local url="$2"
  local expected="$3"
  local label="${4:-HTTP $url}"
  
  local code
  code=$(cmd_value "$node" "curl -s -o /dev/null -w '%{http_code}' '$url' 2>/dev/null || echo '000'")
  
  for exp in $expected; do
    if [[ "$code" == "$exp" ]]; then
      echo -e "  ${GREEN}✓${NC} $label: HTTP $code [pass]"
      return 0
    fi
  done
  
  echo -e "  ${RED}✗${NC} $label: HTTP $code (expected: $expected) [fail]"
  return 1
}

# Check HTTP response contains string
# Usage: assert_http_contains "$node" "url" "expected_string" ["label"]
assert_http_contains() {
  local node="$1"
  local url="$2"
  local expected="$3"
  local label="${4:-HTTP $url}"
  
  local response
  response=$(cmd_clean "$node" "curl -s '$url' 2>/dev/null")
  
  if [[ "$response" == *"$expected"* ]]; then
    echo -e "  ${GREEN}✓${NC} $label contains '$expected' [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label missing '$expected' [fail]"
    return 1
  fi
}

# Check HTTP response contains multiple strings (all must match)
# Usage: assert_http_contains_all "$node" "url" "string1" "string2" ... ["--label" "label"]
assert_http_contains_all() {
  local node="$1"
  local url="$2"
  shift 2
  
  local label="HTTP $url"
  local patterns=()
  
  # Parse arguments - check for --label flag
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--label" ]]; then
      label="$2"
      shift 2
    else
      patterns+=("$1")
      shift
    fi
  done
  
  local response
  response=$(cmd_clean "$node" "curl -s '$url' 2>/dev/null")
  
  for pattern in "${patterns[@]}"; do
    if [[ "$response" != *"$pattern"* ]]; then
      echo -e "  ${RED}✗${NC} $label missing '$pattern' [fail]"
      return 1
    fi
  done
  
  echo -e "  ${GREEN}✓${NC} $label [pass]"
  return 0
}

# ============================================================================
# String Assertions
# ============================================================================

# Check if value equals expected
# Usage: assert_equals "actual" "expected" "label"
assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  
  if [[ "$actual" == "$expected" ]]; then
    echo -e "  ${GREEN}✓${NC} $label [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label: got '$actual', expected '$expected' [fail]"
    return 1
  fi
}

# Check if value contains substring
# Usage: assert_contains "haystack" "needle" "label"
assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}✓${NC} $label [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label: missing '$needle' [fail]"
    return 1
  fi
}

# Check if value contains all substrings
# Usage: assert_contains_all "haystack" "label" "needle1" "needle2" ...
assert_contains_all() {
  local haystack="$1"
  local label="$2"
  shift 2
  
  for needle in "$@"; do
    if [[ "$haystack" != *"$needle"* ]]; then
      echo -e "  ${RED}✗${NC} $label: missing '$needle' [fail]"
      return 1
    fi
  done
  
  echo -e "  ${GREEN}✓${NC} $label [pass]"
  return 0
}

# Check if value is not empty
# Usage: assert_not_empty "value" "label"
assert_not_empty() {
  local value="$1"
  local label="$2"
  
  if [[ -n "$value" ]]; then
    echo -e "  ${GREEN}✓${NC} $label [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label: empty [fail]"
    return 1
  fi
}

# Check if value is empty or nil (for Redis-style responses)
# Usage: assert_empty_or_nil "value" "label"
assert_empty_or_nil() {
  local value="$1"
  local label="$2"
  
  if [[ -z "$value" ]] || [[ "$value" == "nil" ]] || [[ "$value" == "(nil)" ]]; then
    echo -e "  ${GREEN}✓${NC} $label [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label: got '$value', expected empty/nil [fail]"
    return 1
  fi
}

# Check if value does NOT contain error indicators
# Usage: assert_no_error "value" "label"
assert_no_error() {
  local value="$1"
  local label="$2"
  
  if [[ "$value" != *"ERROR"* ]] && [[ "$value" != *"error"* ]] && [[ "$value" != *"Error"* ]]; then
    echo -e "  ${GREEN}✓${NC} $label [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label: error found [fail]"
    return 1
  fi
}

# ============================================================================
# File System Assertions
# ============================================================================

# Check if file exists on remote node
# Usage: assert_file_exists "$node" "/path/to/file" ["label"]
assert_file_exists() {
  local node="$1"
  local path="$2"
  local label="${3:-File $path}"
  
  local result
  result=$(cmd_value "$node" "test -f '$path' && echo 'exists' || echo 'missing'")
  
  if [[ "$result" == "exists" ]]; then
    echo -e "  ${GREEN}✓${NC} $label exists [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label not found [fail]"
    return 1
  fi
}

# Check if directory exists on remote node
# Usage: assert_dir_exists "$node" "/path/to/dir" ["label"]
assert_dir_exists() {
  local node="$1"
  local path="$2"
  local label="${3:-Directory $path}"
  
  local result
  result=$(cmd_value "$node" "test -d '$path' && echo 'exists' || echo 'missing'")
  
  if [[ "$result" == "exists" ]]; then
    echo -e "  ${GREEN}✓${NC} $label exists [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label not found [fail]"
    return 1
  fi
}

# ============================================================================
# Container Assertions
# ============================================================================

# Check if a podman container is running
# Usage: assert_container_running "$node" "container-name" ["label"]
assert_container_running() {
  local node="$1"
  local container="$2"
  local label="${3:-Container $container}"
  
  local status
  status=$(cmd_clean "$node" "podman ps --filter name=$container --format '{{.Names}} {{.Status}}'")
  
  if [[ "$status" == *"$container"* ]]; then
    echo -e "  ${GREEN}✓${NC} $label running [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label not running [fail]"
    return 1
  fi
}

# ============================================================================
# Comparison Assertions
# ============================================================================

# Check if numeric value is greater than or equal to expected
# Usage: assert_gte "actual" "expected" "label"
assert_gte() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  
  if [[ "$actual" -ge "$expected" ]]; then
    echo -e "  ${GREEN}✓${NC} $label ($actual >= $expected) [pass]"
    return 0
  else
    echo -e "  ${RED}✗${NC} $label: $actual < $expected [fail]"
    return 1
  fi
}

# Check if numeric value is less than expected (for ordering/timestamps)
# Usage: assert_lt "actual" "expected" "label"
assert_lt() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  
  if [[ -n "$actual" ]] && [[ -n "$expected" ]] && [[ "$actual" -lt "$expected" ]]; then
    echo -e "  ${GREEN}✓${NC} $label [pass]"
    return 0
  else
    echo -e "  ${YELLOW}!${NC} $label: could not verify [warn]"
    return 1
  fi
}

# ============================================================================
# Soft Assertions (warnings instead of failures)
# ============================================================================

# Soft assertion that shows warning instead of failure
# Usage: assert_warn "condition_result" "label" "warn_message"
# condition_result should be "true" or "false"
assert_warn() {
  local condition="$1"
  local label="$2"
  local warn_msg="${3:-}"
  
  if [[ "$condition" == "true" ]]; then
    echo -e "  ${GREEN}✓${NC} $label [pass]"
    return 0
  else
    if [[ -n "$warn_msg" ]]; then
      echo -e "  ${YELLOW}!${NC} $label ($warn_msg) [warn]"
    else
      echo -e "  ${YELLOW}!${NC} $label [warn]"
    fi
    return 0  # Return success for soft assertions
  fi
}

# ============================================================================
# Utility: Show logs on failure
# ============================================================================

# Show service logs (call after a failed assertion)
# Usage: show_service_logs "$node" "service-name" [lines]
show_service_logs() {
  local node="$1"
  local service="$2"
  local lines="${3:-50}"
  
  echo ""
  echo "Service logs for $service:"
  cmd "$node" "journalctl -n $lines -u $service"
}

# Show container logs (call after a failed assertion)
# Usage: show_container_logs "$node" "container-name" [lines]
show_container_logs() {
  local node="$1"
  local container="$2"
  local lines="${3:-50}"
  
  echo ""
  echo "Container logs for $container:"
  cmd "$node" "podman logs --tail $lines $container"
}
