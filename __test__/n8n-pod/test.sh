#!/usr/bin/env bash
# n8n-pod test for nix-infra-machine
#
# This test:
# 1. Deploys n8n as a podman container with SQLite backend
# 2. Verifies the service is running
# 3. Tests n8n endpoints and functionality
# 4. Cleans up on teardown

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down n8n-pod test..."
  
  # Stop and remove container if running
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop podman-n8n-pod 2>/dev/null || true'
  
  # Clean up data directory
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/n8n-pod'
  
  echo "n8n-pod teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "n8n-pod Test (SQLite, Container)"
echo "========================================"
echo ""

# Deploy the n8n-pod configuration to test nodes
echo "Step 1: Deploying n8n-pod configuration..."
$NIX_INFRA fleet deploy-apps -d "$WORK_DIR" --batch --env="$ENV" \
  --test-dir="$WORK_DIR/$TEST_DIR" \
  --target="$TARGET"

# Apply the configuration
echo "Step 2: Applying NixOS configuration..."
$NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" "nixos-rebuild switch --fast"

_setup=$(date +%s)

# ============================================================================
# Test Verification
# ============================================================================

echo ""
echo "Step 3: Verifying n8n-pod deployment..."
echo ""

# Wait for service, container and HTTP to be ready
for node in $TARGET; do
  wait_for_service "$node" "podman-n8n-pod" --timeout=60
  wait_for_container "$node" "n8n-pod" --timeout=60
  wait_for_port "$node" "5678" --timeout=30
  wait_for_http "$node" "http://localhost:5678/" "200 302 303" --timeout=60
done

# ============================================================================
# Check Service Status
# ============================================================================

echo ""
echo "Checking systemd service status..."
for node in $TARGET; do
  assert_service_active "$node" "podman-n8n-pod" || show_service_logs "$node" "podman-n8n-pod" 50
done

# Check if container is running
echo ""
echo "Checking container status..."
for node in $TARGET; do
  assert_container_running "$node" "n8n-pod" "n8n-pod container"
done

# ============================================================================
# Check Port Bindings
# ============================================================================

echo ""
echo "Step 4: Checking port bindings..."
echo ""

for node in $TARGET; do
  echo "Checking ports on $node..."
  assert_port_listening "$node" "5678" "n8n port 5678"
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 5: Running functional tests..."
echo ""

for node in $TARGET; do
  echo "Testing n8n on $node..."
  
  # Test n8n HTTP response
  echo "  Testing n8n HTTP response..."
  assert_http_status "$node" "http://localhost:5678/" "200 302 303" "HTTP response"
  
  # Test n8n healthcheck endpoint
  echo "  Testing n8n healthcheck endpoint..."
  healthcheck=$(cmd_clean "$node" "curl -s http://localhost:5678/healthz 2>/dev/null")
  if [[ "$healthcheck" == *"ok"* ]] || [[ "$healthcheck" == *"healthy"* ]] || [[ -n "$healthcheck" ]]; then
    echo -e "  ${GREEN}✓${NC} n8n healthcheck responded: $healthcheck [pass]"
  else
    echo -e "  ${YELLOW}!${NC} n8n healthcheck response: $healthcheck [warn]"
  fi
  
  # Test n8n API types endpoint (should list available node types)
  echo "  Testing n8n API endpoint..."
  api_response=$(cmd_clean "$node" "curl -s http://localhost:5678/api/v1/node-types 2>/dev/null | head -c 200")
  if [[ "$api_response" == *"data"* ]] || [[ "$api_response" == *"type"* ]]; then
    echo -e "  ${GREEN}✓${NC} n8n API is responding [pass]"
  else
    echo -e "  ${YELLOW}!${NC} n8n API response: ${api_response:0:100} [warn]"
  fi
  
  # Check n8n data directory exists on host
  echo "  Testing n8n data directory..."
  assert_dir_exists "$node" "/var/lib/n8n-pod" "n8n data directory"
  
  # Check SQLite database file exists (inside container volume)
  echo "  Testing SQLite database file..."
  sqlite_exists=$(cmd_value "$node" "test -f /var/lib/n8n-pod/database.sqlite && echo 'exists' || echo 'missing'")
  assert_warn "$([[ "$sqlite_exists" == "exists" ]] && echo true || echo false)" "SQLite database file exists" "may be created on first use"
  
  # Check container logs for errors
  echo "  Checking container logs for errors..."
  error_logs=$(cmd_clean "$node" "podman logs n8n-pod 2>&1 | grep -i 'error\|fatal' | tail -5 || echo 'none'")
  if [[ "$error_logs" == *"none"* ]] || [[ -z "$error_logs" ]]; then
    echo -e "  ${GREEN}✓${NC} No errors in container logs [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Errors found in logs: $error_logs [warn]"
  fi
  
  # Check container health
  echo "  Checking container process..."
  n8n_process=$(cmd_clean "$node" "podman exec n8n-pod pgrep -f 'n8n' || echo 'not_found'")
  if [[ "$n8n_process" != "not_found" ]] && [[ -n "$n8n_process" ]]; then
    echo -e "  ${GREEN}✓${NC} n8n process is running inside container [pass]"
  else
    echo -e "  ${RED}✗${NC} n8n process not found in container [fail]"
  fi
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "n8n-pod Test Summary (SQLite, Container)"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "n8n-pod Test Complete"
echo "========================================"