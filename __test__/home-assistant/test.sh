#!/usr/bin/env bash
# Home Assistant test for nix-infra-machine
#
# This test:
# 1. Deploys Home Assistant with the infrastructure module
# 2. Verifies the service is running
# 3. Tests Home Assistant endpoints and functionality
# 4. Cleans up on teardown

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down Home Assistant test..."
  
  # Stop services
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop home-assistant 2>/dev/null || true'
  
  # Clean up data directories
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/hass'
  
  echo "Home Assistant teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "Home Assistant Test"
echo "========================================"
echo ""

# Deploy the home-assistant configuration to test nodes
echo "Step 1: Deploying Home Assistant configuration..."
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
echo "Step 3: Verifying Home Assistant deployment..."
echo ""

# Wait for service and HTTP to be ready (Home Assistant can take a while to initialize)
for node in $TARGET; do
  wait_for_service "$node" "home-assistant" --timeout=60
  wait_for_port "$node" "8123" --timeout=30
  wait_for_http "$node" "http://localhost:8123/" "200 302 303" --timeout=90
done

# ============================================================================
# Check Service Status
# ============================================================================

echo ""
echo "Checking systemd services status..."
echo ""

for node in $TARGET; do
  echo "Checking services on $node..."
  assert_service_active "$node" "home-assistant" || show_service_logs "$node" "home-assistant" 100
done

# ============================================================================
# Check Port Bindings
# ============================================================================

echo ""
echo "Step 4: Checking port bindings..."
echo ""

for node in $TARGET; do
  echo "Checking ports on $node..."
  assert_port_listening "$node" "8123" "Home Assistant port 8123"
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 5: Running functional tests..."
echo ""

for node in $TARGET; do
  echo "Testing Home Assistant on $node..."
  
  # Test Home Assistant HTTP response
  echo "  Testing Home Assistant HTTP response..."
  assert_http_status "$node" "http://localhost:8123/" "200 302 303" "HTTP response"
  
  # Test Home Assistant API health check
  echo "  Testing Home Assistant API health..."
  api_response=$(cmd_clean "$node" "curl -s http://localhost:8123/api/ 2>/dev/null")
  if [[ "$api_response" == *"API running"* ]] || [[ "$api_response" == *"message"* ]]; then
    echo -e "  ${GREEN}✓${NC} Home Assistant API is responding [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Home Assistant API response: ${api_response:0:100} [warn]"
  fi
  
  # Test Home Assistant manifest
  echo "  Testing Home Assistant manifest endpoint..."
  manifest_response=$(cmd_clean "$node" "curl -s http://localhost:8123/manifest.json 2>/dev/null")
  assert_contains "$manifest_response" "Home Assistant" "Home Assistant manifest is accessible"
  
  # Test Home Assistant frontend assets
  echo "  Testing Home Assistant frontend..."
  assert_http_status "$node" "http://localhost:8123/frontend_latest/app.js" "200" "Frontend assets accessible"
  
  # Check configuration directory exists
  echo "  Testing configuration directory..."
  assert_dir_exists "$node" "/var/lib/hass" "Configuration directory"
  
  # Check configuration file exists
  echo "  Testing configuration.yaml..."
  config_file=$(cmd_value "$node" "test -f /var/lib/hass/configuration.yaml && echo 'exists' || echo 'missing'")
  assert_warn "$([[ "$config_file" == "exists" ]] && echo true || echo false)" "configuration.yaml exists" "may be using NixOS-managed config"
  
  # Check Home Assistant database
  echo "  Testing Home Assistant database..."
  db_exists=$(cmd_value "$node" "test -f /var/lib/hass/home-assistant_v2.db && echo 'exists' || echo 'missing'")
  assert_warn "$([[ "$db_exists" == "exists" ]] && echo true || echo false)" "Home Assistant database exists" "may still be initializing"
  
  # Check service is not in error state
  echo "  Checking service state..."
  assert_service_running "$node" "home-assistant" "Service running normally"
  
  # Check for any failed units related to home-assistant
  echo "  Checking for failed units..."
  failed_units=$(cmd_clean "$node" "systemctl list-units --failed | grep -i home || echo 'none'")
  if [[ "$failed_units" == *"none"* ]] || [[ -z "$failed_units" ]]; then
    echo -e "  ${GREEN}✓${NC} No failed home-assistant related units [pass]"
  else
    echo -e "  ${RED}✗${NC} Failed units found: $failed_units [fail]"
  fi
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "Home Assistant Test Summary"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "Home Assistant Test Complete"
echo "========================================"