#!/usr/bin/env bash
# Redis test for nix-infra-machine
#
# This test:
# 1. Deploys multiple Redis servers using infrastructure.redis
# 2. Verifies all services are running
# 3. Tests basic Redis operations on each server
# 4. Cleans up on teardown

# Server configurations: name:port
declare -A REDIS_SERVERS=(
  ["redis"]=6379
  ["redis-cache"]=6380
)

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down Redis test..."
  
  # Stop Redis services
  for server in "${!REDIS_SERVERS[@]}"; do
    $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
      "systemctl stop $server 2>/dev/null || true"
  done
  
  # Clean up data directories
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/redis /var/lib/redis-cache'
  
  echo "Redis teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "Redis Multi-Server Test"
echo "========================================"
echo ""

# Deploy the redis configuration to test nodes
echo "Step 1: Deploying Redis configuration..."
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
echo "Step 3: Verifying Redis deployment..."
echo ""

# Wait for services to start
for node in $TARGET; do
  for server in "${!REDIS_SERVERS[@]}"; do
    port=${REDIS_SERVERS[$server]}
    wait_for_service "$node" "$server" --timeout=30
    wait_for_redis "$node" "$port" --timeout=15
  done
done

# Check if the systemd services are active
echo ""
echo "Checking systemd service status..."
for node in $TARGET; do
  for server in "${!REDIS_SERVERS[@]}"; do
    assert_service_active "$node" "$server" || show_service_logs "$node" "$server" 30
  done
done

# Check if Redis processes are running
echo ""
echo "Checking Redis processes..."
for node in $TARGET; do
  expected_count=${#REDIS_SERVERS[@]}
  assert_process_count "$node" "redis-server" "$expected_count" "Redis"
done

# Check if Redis ports are listening
echo ""
echo "Checking Redis ports..."
for node in $TARGET; do
  for server in "${!REDIS_SERVERS[@]}"; do
    port=${REDIS_SERVERS[$server]}
    assert_port_listening "$node" "$port" "$server port $port"
  done
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 4: Running functional tests..."
echo ""

# Test Redis connection and basic operations on each server
for node in $TARGET; do
  for server in "${!REDIS_SERVERS[@]}"; do
    port=${REDIS_SERVERS[$server]}
    echo "Testing $server (port $port) on $node..."
    
    # Test PING command
    echo "  Testing PING command..."
    ping_result=$(cmd_clean "$node" "redis-cli -p $port PING")
    assert_contains "$ping_result" "PONG" "PING successful"
    
    # Test SET command
    echo "  Testing SET command..."
    set_result=$(cmd_clean "$node" "redis-cli -p $port SET testkey-$server 'hello-from-$server'")
    assert_contains "$set_result" "OK" "SET operation successful"
    
    # Test GET command
    echo "  Testing GET command..."
    get_result=$(cmd_clean "$node" "redis-cli -p $port GET testkey-$server")
    assert_contains "$get_result" "hello-from-$server" "GET operation successful"
    
    # Test INCR command
    echo "  Testing INCR command..."
    cmd "$node" "redis-cli -p $port SET counter 0" > /dev/null 2>&1
    incr_result=$(cmd_clean "$node" "redis-cli -p $port INCR counter")
    assert_contains "$incr_result" "1" "INCR operation successful"
    
    # Test INFO command
    echo "  Testing INFO command..."
    info_result=$(cmd_clean "$node" "redis-cli -p $port INFO server | head -5")
    assert_contains "$info_result" "redis_version" "INFO command successful"
    
    # Clean up test data
    echo "  Cleaning up test data..."
    cmd "$node" "redis-cli -p $port FLUSHALL" > /dev/null 2>&1
    print_cleanup "Test data cleaned up"
    echo ""
  done
done

# ============================================================================
# Test Server Isolation
# ============================================================================

echo "Step 5: Testing server isolation..."
echo ""

for node in $TARGET; do
  echo "Testing data isolation on $node..."
  
  # Set a key on the default server
  cmd "$node" "redis-cli -p 6379 SET isolation-test 'default-server'" > /dev/null 2>&1
  
  # Try to get it from the cache server (should not exist)
  cache_result=$(cmd_value "$node" "redis-cli -p 6380 GET isolation-test")
  assert_empty_or_nil "$cache_result" "Servers are properly isolated"
  
  # Clean up
  cmd "$node" "redis-cli -p 6379 FLUSHALL" > /dev/null 2>&1
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "Redis Test Summary"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "Redis Test Complete"
echo "========================================"