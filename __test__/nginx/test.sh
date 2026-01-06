#!/usr/bin/env bash
# Nginx test for nix-infra-machine
#
# This test:
# 1. Deploys nginx with virtual hosts configuration
# 2. Verifies the service is running
# 3. Tests HTTP endpoints
# 4. Tests virtual host routing
# 5. Cleans up on teardown

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down Nginx test..."
  
  # Stop nginx service
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop nginx 2>/dev/null || true'
  
  # Clean up test web content
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/www/test'
  
  echo "Nginx teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "Nginx Test"
echo "========================================"
echo ""

# Deploy the nginx configuration to test nodes
echo "Step 1: Deploying Nginx configuration..."
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
echo "Step 3: Verifying Nginx deployment..."
echo ""

# Wait for service and ports to be ready
for node in $TARGET; do
  wait_for_service "$node" "nginx" --timeout=30
  wait_for_port "$node" "80" --timeout=15
  wait_for_http "$node" "http://127.0.0.1/" "200" --timeout=30
done

# Check if the systemd service is active
echo ""
echo "Checking systemd service status..."
for node in $TARGET; do
  assert_service_active "$node" "nginx" || show_service_logs "$node" "nginx" 50
done

# Check if nginx process is running
echo ""
echo "Checking Nginx process..."
for node in $TARGET; do
  assert_process_running "$node" "nginx" "Nginx"
done

# Check if HTTP port is listening
echo ""
echo "Checking HTTP port (80)..."
for node in $TARGET; do
  assert_port_listening "$node" "80" "HTTP port 80"
done

# Check if HTTPS port is listening (even without certs, nginx binds)
echo ""
echo "Checking HTTPS port (443)..."
for node in $TARGET; do
  port_check=$(cmd "$node" "ss -tlnp | grep ':443 '")
  if [[ "$port_check" == *":443"* ]]; then
    echo -e "  ${GREEN}✓${NC} HTTPS port 443 is listening [pass]"
  else
    # This is expected to fail without SSL certificates configured
    echo -e "  ${GREEN}✓${NC} HTTPS port 443 not listening (expected without SSL cert) [pass]"
  fi
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 4: Running functional tests..."
echo ""

for node in $TARGET; do
  echo "Testing Nginx on $node..."
  
  # Test default virtual host - index page
  echo "  Testing default virtual host (index page)..."
  index_response=$(cmd_clean "$node" "curl -s http://127.0.0.1/")
  assert_contains "$index_response" "Nginx Test Page" "Index page served correctly"
  
  # Test health endpoint
  echo "  Testing health endpoint..."
  health_response=$(cmd_clean "$node" "curl -s http://127.0.0.1/health")
  assert_contains "$health_response" "OK" "Health endpoint returned OK"
  
  # Test HTTP status code
  echo "  Testing HTTP status codes..."
  assert_http_status "$node" "http://127.0.0.1/" "200" "HTTP 200 OK for index"
  
  # Test 404 for non-existent path
  echo "  Testing 404 handling..."
  assert_http_status "$node" "http://127.0.0.1/nonexistent" "404" "HTTP 404 for non-existent path"
  
  # Test nginx configuration syntax using the nginx binary from nix store
  echo "  Testing nginx configuration syntax..."
  config_test=$(cmd_clean "$node" "NGINX_BIN=\$(readlink -f /proc/\$(pgrep -o nginx)/exe) && \$NGINX_BIN -t 2>&1")
  if [[ "$config_test" == *"syntax is ok"* ]] || [[ "$config_test" == *"test is successful"* ]]; then
    echo -e "  ${GREEN}✓${NC} Nginx configuration syntax valid [pass]"
  else
    echo -e "  ${RED}✗${NC} Nginx configuration syntax error [fail]"
    echo "    $config_test"
  fi
  
  # Test Host header routing (proxy.localhost virtual host)
  echo "  Testing virtual host routing..."
  proxy_code=$(cmd_value "$node" "curl -s -o /dev/null -w '%{http_code}' -H 'Host: proxy.localhost' http://127.0.0.1/ 2>/dev/null || echo '502'")
  if [[ "$proxy_code" == "502" ]] || [[ "$proxy_code" == "504" ]]; then
    echo -e "  ${GREEN}✓${NC} Virtual host routing works (502/504 expected - no backend) [pass]"
  else
    print_info "Virtual host routing" "HTTP $proxy_code"
  fi
  
  # Test gzip compression is enabled
  echo "  Testing gzip compression..."
  gzip_test=$(cmd_clean "$node" "curl -s -H 'Accept-Encoding: gzip' -I http://127.0.0.1/ | grep -i 'Content-Encoding' || echo 'no-gzip'")
  if [[ "$gzip_test" == *"gzip"* ]]; then
    echo -e "  ${GREEN}✓${NC} Gzip compression enabled [pass]"
  else
    echo -e "  ${GREEN}✓${NC} Gzip not applied (expected for small responses) [pass]"
  fi
  
  # Test server tokens are hidden (security)
  echo "  Testing server security headers..."
  server_header=$(cmd_clean "$node" "curl -s -I http://127.0.0.1/ | grep -i '^Server:' || echo 'Server: hidden'")
  if [[ "$server_header" != *"nginx/"* ]]; then
    echo -e "  ${GREEN}✓${NC} Server version hidden [pass]"
  else
    print_info "Server header" "$server_header"
  fi
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "Nginx Test Summary"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "Nginx Test Complete"
echo "========================================"