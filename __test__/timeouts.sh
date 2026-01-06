#!/usr/bin/env bash
# Timeout handling library for nix-infra-machine tests
# Provides functions to wait for conditions with configurable timeouts
#
# All wait functions follow this pattern:
#   wait_for_* [args...] [--timeout=N] [--interval=N] [--silent]
#   Returns 0 on success, 1 on timeout
#   Prints progress unless --silent is specified
#
# Requires: cmd, cmd_value, cmd_clean functions from shared.sh
# Requires: Colors (GREEN, RED, YELLOW, NC) from shared.sh

# Default timeout values (can be overridden)
DEFAULT_TIMEOUT=60
DEFAULT_INTERVAL=2

# ============================================================================
# Generic Wait Function
# ============================================================================

# Wait for a condition to be true
# Usage: wait_for_condition "label" "command" "expected_pattern" [--timeout=N] [--interval=N] [--silent]
# The command is run locally (not on a remote node)
wait_for_condition() {
  local label="$1"
  local command="$2"
  local expected="$3"
  shift 3
  
  local timeout=$DEFAULT_TIMEOUT
  local interval=$DEFAULT_INTERVAL
  local silent=false
  
  # Parse optional arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      --silent) silent=true ;;
      *) ;;
    esac
    shift
  done
  
  [[ "$silent" == false ]] && echo -n "  Waiting for $label (${timeout}s timeout)..."
  
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local result
    result=$(eval "$command" 2>/dev/null)
    
    if [[ "$result" == *"$expected"* ]]; then
      [[ "$silent" == false ]] && echo -e " ${GREEN}ready${NC} (${elapsed}s)"
      return 0
    fi
    
    [[ "$silent" == false ]] && echo -n "."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  [[ "$silent" == false ]] && echo -e " ${RED}timeout${NC}"
  return 1
}

# ============================================================================
# Service Wait Functions
# ============================================================================

# Wait for a systemd service to become active
# Usage: wait_for_service "$node" "service-name" [--timeout=N] [--interval=N] [--silent]
wait_for_service() {
  local node="$1"
  local service="$2"
  shift 2
  
  local timeout=$DEFAULT_TIMEOUT
  local interval=$DEFAULT_INTERVAL
  local silent=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      --silent) silent=true ;;
      *) ;;
    esac
    shift
  done
  
  [[ "$silent" == false ]] && echo -n "  Waiting for $service to be active (${timeout}s timeout)..."
  
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local status
    status=$(cmd_value "$node" "systemctl is-active $service 2>/dev/null || echo 'unknown'")
    
    if [[ "$status" == "active" ]]; then
      [[ "$silent" == false ]] && echo -e " ${GREEN}active${NC} (${elapsed}s)"
      return 0
    fi
    
    [[ "$silent" == false ]] && echo -n "."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  [[ "$silent" == false ]] && echo -e " ${RED}timeout${NC} (status: $status)"
  return 1
}

# Wait for a oneshot service to complete successfully
# Usage: wait_for_service_completed "$node" "service-name" [--timeout=N] [--interval=N] [--silent]
wait_for_service_completed() {
  local node="$1"
  local service="$2"
  shift 2
  
  local timeout=$DEFAULT_TIMEOUT
  local interval=$DEFAULT_INTERVAL
  local silent=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      --silent) silent=true ;;
      *) ;;
    esac
    shift
  done
  
  [[ "$silent" == false ]] && echo -n "  Waiting for $service to complete (${timeout}s timeout)..."
  
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local status
    status=$(cmd_value "$node" "systemctl is-active $service 2>/dev/null || echo 'unknown'")
    
    if [[ "$status" == "inactive" ]]; then
      # Check exit status
      local exit_status
      exit_status=$(cmd_value "$node" "systemctl show -p ExecMainStatus $service --value")
      if [[ "$exit_status" == "0" ]]; then
        [[ "$silent" == false ]] && echo -e " ${GREEN}completed${NC} (${elapsed}s)"
        return 0
      else
        [[ "$silent" == false ]] && echo -e " ${RED}failed${NC} (exit: $exit_status)"
        return 1
      fi
    elif [[ "$status" == "failed" ]]; then
      [[ "$silent" == false ]] && echo -e " ${RED}failed${NC}"
      return 1
    fi
    
    [[ "$silent" == false ]] && echo -n "."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  [[ "$silent" == false ]] && echo -e " ${RED}timeout${NC}"
  return 1
}

# ============================================================================
# Port Wait Functions
# ============================================================================

# Wait for a port to start listening
# Usage: wait_for_port "$node" "port" [--timeout=N] [--interval=N] [--silent]
wait_for_port() {
  local node="$1"
  local port="$2"
  shift 2
  
  local timeout=$DEFAULT_TIMEOUT
  local interval=$DEFAULT_INTERVAL
  local silent=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      --silent) silent=true ;;
      *) ;;
    esac
    shift
  done
  
  [[ "$silent" == false ]] && echo -n "  Waiting for port $port to listen (${timeout}s timeout)..."
  
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local result
    result=$(cmd "$node" "ss -tlnp 2>/dev/null | grep ':$port '" 2>/dev/null)
    
    if [[ "$result" == *":$port"* ]]; then
      [[ "$silent" == false ]] && echo -e " ${GREEN}listening${NC} (${elapsed}s)"
      return 0
    fi
    
    [[ "$silent" == false ]] && echo -n "."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  [[ "$silent" == false ]] && echo -e " ${RED}timeout${NC}"
  return 1
}

# Wait for multiple ports to start listening
# Usage: wait_for_ports "$node" "port1 port2 port3" [--timeout=N] [--interval=N]
wait_for_ports() {
  local node="$1"
  local ports="$2"
  shift 2
  
  local timeout=$DEFAULT_TIMEOUT
  local interval=$DEFAULT_INTERVAL
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      *) ;;
    esac
    shift
  done
  
  for port in $ports; do
    if ! wait_for_port "$node" "$port" --timeout="$timeout" --interval="$interval"; then
      return 1
    fi
  done
  
  return 0
}

# ============================================================================
# HTTP Wait Functions
# ============================================================================

# Wait for an HTTP endpoint to respond with expected status code
# Usage: wait_for_http "$node" "url" "expected_codes" [--timeout=N] [--interval=N] [--silent]
# expected_codes can be space-separated: "200 302 303"
wait_for_http() {
  local node="$1"
  local url="$2"
  local expected="${3:-200}"
  shift 3
  
  local timeout=$DEFAULT_TIMEOUT
  local interval=$DEFAULT_INTERVAL
  local silent=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      --silent) silent=true ;;
      *) ;;
    esac
    shift
  done
  
  [[ "$silent" == false ]] && echo -n "  Waiting for HTTP $url (${timeout}s timeout)..."
  
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local code
    code=$(cmd_value "$node" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 '$url' 2>/dev/null || echo '000'")
    
    for exp in $expected; do
      if [[ "$code" == "$exp" ]]; then
        [[ "$silent" == false ]] && echo -e " ${GREEN}HTTP $code${NC} (${elapsed}s)"
        return 0
      fi
    done
    
    [[ "$silent" == false ]] && echo -n "."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  [[ "$silent" == false ]] && echo -e " ${RED}timeout${NC} (last: HTTP $code)"
  return 1
}

# Wait for an HTTP endpoint to contain expected content
# Usage: wait_for_http_content "$node" "url" "expected_string" [--timeout=N] [--interval=N] [--silent]
wait_for_http_content() {
  local node="$1"
  local url="$2"
  local expected="$3"
  shift 3
  
  local timeout=$DEFAULT_TIMEOUT
  local interval=$DEFAULT_INTERVAL
  local silent=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      --silent) silent=true ;;
      *) ;;
    esac
    shift
  done
  
  [[ "$silent" == false ]] && echo -n "  Waiting for HTTP content '$expected' (${timeout}s timeout)..."
  
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local response
    response=$(cmd_clean "$node" "curl -s --max-time 5 '$url' 2>/dev/null")
    
    if [[ "$response" == *"$expected"* ]]; then
      [[ "$silent" == false ]] && echo -e " ${GREEN}found${NC} (${elapsed}s)"
      return 0
    fi
    
    [[ "$silent" == false ]] && echo -n "."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  [[ "$silent" == false ]] && echo -e " ${RED}timeout${NC}"
  return 1
}

# ============================================================================
# Container Wait Functions
# ============================================================================

# Wait for a podman container to be running
# Usage: wait_for_container "$node" "container-name" [--timeout=N] [--interval=N] [--silent]
wait_for_container() {
  local node="$1"
  local container="$2"
  shift 2
  
  local timeout=$DEFAULT_TIMEOUT
  local interval=$DEFAULT_INTERVAL
  local silent=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      --silent) silent=true ;;
      *) ;;
    esac
    shift
  done
  
  [[ "$silent" == false ]] && echo -n "  Waiting for container $container (${timeout}s timeout)..."
  
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local status
    status=$(cmd_clean "$node" "podman ps --filter name=$container --format '{{.Status}}' 2>/dev/null")
    
    if [[ "$status" == *"Up"* ]]; then
      [[ "$silent" == false ]] && echo -e " ${GREEN}running${NC} (${elapsed}s)"
      return 0
    fi
    
    [[ "$silent" == false ]] && echo -n "."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  [[ "$silent" == false ]] && echo -e " ${RED}timeout${NC}"
  return 1
}

# ============================================================================
# Database Wait Functions
# ============================================================================

# Wait for PostgreSQL to accept connections
# Usage: wait_for_postgresql "$node" [--timeout=N] [--interval=N] [--silent]
wait_for_postgresql() {
  local node="$1"
  shift
  
  local timeout=$DEFAULT_TIMEOUT
  local interval=$DEFAULT_INTERVAL
  local silent=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      --silent) silent=true ;;
      *) ;;
    esac
    shift
  done
  
  [[ "$silent" == false ]] && echo -n "  Waiting for PostgreSQL to accept connections (${timeout}s timeout)..."
  
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local result
    result=$(cmd_clean "$node" "sudo -u postgres psql -c 'SELECT 1;' 2>/dev/null")
    
    if [[ "$result" == *"1"* ]]; then
      [[ "$silent" == false ]] && echo -e " ${GREEN}ready${NC} (${elapsed}s)"
      return 0
    fi
    
    [[ "$silent" == false ]] && echo -n "."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  [[ "$silent" == false ]] && echo -e " ${RED}timeout${NC}"
  return 1
}

# Wait for Redis to respond to PING
# Usage: wait_for_redis "$node" [port] [--timeout=N] [--interval=N] [--silent]
wait_for_redis() {
  local node="$1"
  local port="${2:-6379}"
  shift 2 2>/dev/null || shift 1
  
  local timeout=$DEFAULT_TIMEOUT
  local interval=$DEFAULT_INTERVAL
  local silent=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      --silent) silent=true ;;
      *) ;;
    esac
    shift
  done
  
  [[ "$silent" == false ]] && echo -n "  Waiting for Redis on port $port (${timeout}s timeout)..."
  
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local result
    result=$(cmd_clean "$node" "redis-cli -p $port PING 2>/dev/null")
    
    if [[ "$result" == *"PONG"* ]]; then
      [[ "$silent" == false ]] && echo -e " ${GREEN}ready${NC} (${elapsed}s)"
      return 0
    fi
    
    [[ "$silent" == false ]] && echo -n "."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  [[ "$silent" == false ]] && echo -e " ${RED}timeout${NC}"
  return 1
}

# Wait for MongoDB to accept connections
# Usage: wait_for_mongodb "$node" [port] [--timeout=N] [--interval=N] [--silent]
wait_for_mongodb() {
  local node="$1"
  local port="${2:-27017}"
  shift 2 2>/dev/null || shift 1
  
  local timeout=$DEFAULT_TIMEOUT
  local interval=$DEFAULT_INTERVAL
  local silent=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      --silent) silent=true ;;
      *) ;;
    esac
    shift
  done
  
  [[ "$silent" == false ]] && echo -n "  Waiting for MongoDB on port $port (${timeout}s timeout)..."
  
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local result
    result=$(cmd_clean "$node" "mongosh --port $port --quiet --eval 'db.runCommand({ping:1})' 2>/dev/null")
    
    if [[ "$result" == *"ok"* ]]; then
      [[ "$silent" == false ]] && echo -e " ${GREEN}ready${NC} (${elapsed}s)"
      return 0
    fi
    
    [[ "$silent" == false ]] && echo -n "."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  [[ "$silent" == false ]] && echo -e " ${RED}timeout${NC}"
  return 1
}

# Wait for Elasticsearch/OpenSearch cluster to be ready
# Usage: wait_for_elasticsearch "$node" [port] [--timeout=N] [--interval=N] [--silent]
wait_for_elasticsearch() {
  local node="$1"
  local port="${2:-9200}"
  shift 2 2>/dev/null || shift 1
  
  local timeout=${DEFAULT_TIMEOUT:-60}
  local interval=$DEFAULT_INTERVAL
  local silent=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      --interval=*) interval="${1#*=}" ;;
      --silent) silent=true ;;
      *) ;;
    esac
    shift
  done
  
  [[ "$silent" == false ]] && echo -n "  Waiting for Elasticsearch on port $port (${timeout}s timeout)..."
  
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local result
    result=$(cmd_clean "$node" "curl -s http://127.0.0.1:$port/_cluster/health 2>/dev/null")
    
    if [[ "$result" == *"cluster_name"* ]]; then
      local status
      status=$(echo "$result" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
      [[ "$silent" == false ]] && echo -e " ${GREEN}ready${NC} (status: $status, ${elapsed}s)"
      return 0
    fi
    
    [[ "$silent" == false ]] && echo -n "."
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  
  [[ "$silent" == false ]] && echo -e " ${RED}timeout${NC}"
  return 1
}

# ============================================================================
# Composite Wait Functions
# ============================================================================

# Wait for a service and its port to be ready
# Usage: wait_for_service_and_port "$node" "service" "port" [--timeout=N]
wait_for_service_and_port() {
  local node="$1"
  local service="$2"
  local port="$3"
  shift 3
  
  local timeout=$DEFAULT_TIMEOUT
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      *) ;;
    esac
    shift
  done
  
  # Split timeout between service and port
  local half_timeout=$((timeout / 2))
  
  if ! wait_for_service "$node" "$service" --timeout="$half_timeout"; then
    return 1
  fi
  
  if ! wait_for_port "$node" "$port" --timeout="$half_timeout"; then
    return 1
  fi
  
  return 0
}

# Wait for multiple services to be active
# Usage: wait_for_services "$node" "svc1 svc2 svc3" [--timeout=N]
wait_for_services() {
  local node="$1"
  local services="$2"
  shift 2
  
  local timeout=$DEFAULT_TIMEOUT
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout=*) timeout="${1#*=}" ;;
      *) ;;
    esac
    shift
  done
  
  for service in $services; do
    if ! wait_for_service "$node" "$service" --timeout="$timeout"; then
      return 1
    fi
  done
  
  return 0
}

# ============================================================================
# Timeout Wrapper
# ============================================================================

# Run a command with a timeout (uses bash timeout if available)
# Usage: with_timeout 30 "command to run"
with_timeout() {
  local timeout="$1"
  shift
  local command="$*"
  
  if command -v timeout &> /dev/null; then
    timeout "$timeout" bash -c "$command"
  else
    # Fallback for systems without timeout command
    eval "$command" &
    local pid=$!
    local count=0
    while kill -0 $pid 2>/dev/null; do
      sleep 1
      count=$((count + 1))
      if [[ $count -ge $timeout ]]; then
        kill -9 $pid 2>/dev/null
        return 124  # Same exit code as timeout command
      fi
    done
    wait $pid
    return $?
  fi
}