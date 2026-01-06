#!/usr/bin/env bash
# Nextcloud test for nix-infra-machine
#
# This test:
# 1. Deploys Nextcloud with PostgreSQL, Redis, and Nginx
# 2. Verifies all services are running and started in correct order
# 3. Tests Nextcloud endpoints and functionality
# 4. Cleans up on teardown

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down Nextcloud test..."
  
  # Stop services in reverse order
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop nginx 2>/dev/null || true'
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop phpfpm-nextcloud 2>/dev/null || true'
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop nextcloud-cron 2>/dev/null || true'
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop redis-nextcloud 2>/dev/null || true'
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop postgresql 2>/dev/null || true'
  
  # Clean up data directories
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/nextcloud /var/lib/postgresql /var/lib/redis-nextcloud /run/secrets/nextcloud-admin-pass'
  
  echo "Nextcloud teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "Nextcloud Test"
echo "========================================"
echo ""

# Deploy the nextcloud configuration to test nodes
echo "Step 1: Deploying Nextcloud configuration..."
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
echo "Step 3: Verifying Nextcloud deployment..."
echo ""

# Wait for services to start (Nextcloud has multiple dependencies)
for node in $TARGET; do
  # Wait for backend services first
  wait_for_service "$node" "postgresql" --timeout=30
  wait_for_postgresql "$node" --timeout=30
  wait_for_service "$node" "redis-nextcloud" --timeout=30
  wait_for_redis "$node" "6379" --timeout=15
  
  # Wait for nextcloud-setup oneshot to complete
  wait_for_service_completed "$node" "nextcloud-setup" --timeout=120
  
  # Wait for web services
  wait_for_service "$node" "phpfpm-nextcloud" --timeout=30
  wait_for_service "$node" "nginx" --timeout=30
  wait_for_port "$node" "80" --timeout=15
  wait_for_http "$node" "http://localhost/" "200 302 303" --timeout=60
done

# ============================================================================
# Check Service Status
# ============================================================================

echo ""
echo "Checking systemd services status..."
echo ""

for node in $TARGET; do
  echo "Checking services on $node..."
  
  # Check regular services
  assert_service_active "$node" "postgresql" || show_service_logs "$node" "postgresql" 50
  assert_service_active "$node" "redis-nextcloud" || show_service_logs "$node" "redis-nextcloud" 50
  
  # Check oneshot service (nextcloud-setup)
  assert_service_completed "$node" "nextcloud-setup" || show_service_logs "$node" "nextcloud-setup" 50
  
  # Check remaining services
  assert_service_active "$node" "phpfpm-nextcloud" || show_service_logs "$node" "phpfpm-nextcloud" 50
  assert_service_active "$node" "nginx" || show_service_logs "$node" "nginx" 50
done

# ============================================================================
# Check Service Dependencies
# ============================================================================

echo ""
echo "Step 4: Verifying service dependencies..."
echo ""

for node in $TARGET; do
  echo "Checking service dependencies on $node..."
  
  # Check PostgreSQL started before nextcloud-setup
  pg_start=$(cmd_value "$node" "systemctl show -p ActiveEnterTimestampMonotonic postgresql --value")
  nc_setup_start=$(cmd_value "$node" "systemctl show -p ActiveEnterTimestampMonotonic nextcloud-setup --value")
  assert_lt "$pg_start" "$nc_setup_start" "PostgreSQL started before nextcloud-setup"
  
  # Check Redis started before nextcloud-setup
  redis_start=$(cmd_value "$node" "systemctl show -p ActiveEnterTimestampMonotonic redis-nextcloud --value")
  assert_lt "$redis_start" "$nc_setup_start" "Redis started before nextcloud-setup"
  
  # Check nextcloud-setup completed before phpfpm-nextcloud
  phpfpm_start=$(cmd_value "$node" "systemctl show -p ActiveEnterTimestampMonotonic phpfpm-nextcloud --value")
  assert_lt "$nc_setup_start" "$phpfpm_start" "nextcloud-setup completed before phpfpm-nextcloud"
  
  # Check phpfpm-nextcloud started before nginx
  nginx_start=$(cmd_value "$node" "systemctl show -p ActiveEnterTimestampMonotonic nginx --value")
  assert_lt "$phpfpm_start" "$nginx_start" "phpfpm-nextcloud started before nginx"
done

# ============================================================================
# Check Port Bindings
# ============================================================================

echo ""
echo "Step 5: Checking port bindings..."
echo ""

for node in $TARGET; do
  echo "Checking ports on $node..."
  assert_port_listening "$node" "5432" "PostgreSQL port 5432"
  assert_port_listening "$node" "6379" "Redis port 6379"
  assert_port_listening "$node" "80" "HTTP port 80"
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 6: Running functional tests..."
echo ""

for node in $TARGET; do
  echo "Testing Nextcloud on $node..."
  
  # Test Nextcloud HTTP response
  echo "  Testing Nextcloud HTTP response..."
  assert_http_status "$node" "http://localhost/" "200 302 303" "HTTP response"
  
  # Test Nextcloud login page
  echo "  Testing Nextcloud login page..."
  login_page=$(cmd_clean "$node" "curl -s -L http://localhost/login 2>/dev/null | head -c 2000")
  if [[ "$login_page" == *"Nextcloud"* ]] || [[ "$login_page" == *"login"* ]]; then
    echo -e "  ${GREEN}✓${NC} Nextcloud login page is accessible [pass]"
  else
    echo -e "  ${RED}✗${NC} Nextcloud login page not accessible [fail]"
    echo "    Response preview: ${login_page:0:200}..."
  fi
  
  # Test Nextcloud status endpoint
  echo "  Testing Nextcloud status endpoint..."
  status_response=$(cmd_clean "$node" "curl -s http://localhost/status.php 2>/dev/null")
  if assert_contains_all "$status_response" "Nextcloud is installed (status.php)" "installed" "true"; then
    version=$(echo "$status_response" | grep -o '"versionstring":"[^"]*"' | cut -d'"' -f4)
    if [[ -n "$version" ]]; then
      print_info "Nextcloud version" "$version"
    fi
  fi
  
  # Test PostgreSQL database connection
  echo "  Testing PostgreSQL database..."
  db_check=$(cmd_clean "$node" "sudo -u postgres psql -l | grep nextcloud")
  assert_contains "$db_check" "nextcloud" "Nextcloud database exists in PostgreSQL"
  
  # Test Redis connection
  echo "  Testing Redis connection..."
  redis_check=$(cmd_clean "$node" "redis-cli -p 6379 PING 2>/dev/null")
  assert_contains "$redis_check" "PONG" "Redis is responding"
  
  # Test Nextcloud OCC command
  echo "  Testing Nextcloud OCC command..."
  occ_check=$(cmd_clean "$node" "sudo -u nextcloud /run/current-system/sw/bin/nextcloud-occ status 2>/dev/null")
  assert_contains "$occ_check" "installed: true" "Nextcloud OCC reports installed"
  
  # Test admin user exists
  echo "  Testing admin user exists..."
  admin_check=$(cmd_clean "$node" "sudo -u nextcloud /run/current-system/sw/bin/nextcloud-occ user:list 2>/dev/null | grep admin")
  assert_contains "$admin_check" "admin" "Admin user exists"
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "Nextcloud Test Summary"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "Nextcloud Test Complete"
echo "========================================"