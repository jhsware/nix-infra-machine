#!/usr/bin/env bash
# MongoDB standalone test for nix-infra-machine
#
# This test:
# 1. Deploys MongoDB as a podman container
# 2. Verifies the service is running
# 3. Tests basic MongoDB operations (insert/query)
# 4. Cleans up on teardown

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down MongoDB test..."
  
  # Stop and remove container if running
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop podman-mongodb 2>/dev/null || true'
  
  # Clean up data directory
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/mongodb-pod'
  
  echo "MongoDB teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "MongoDB Standalone Test (Podman)"
echo "========================================"
echo ""

# Deploy the mongodb configuration to test nodes
echo "Step 1: Deploying MongoDB configuration..."
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
echo "Step 3: Verifying MongoDB deployment..."
echo ""

# Wait for service and container to be ready
for node in $TARGET; do
  wait_for_service "$node" "podman-mongodb" --timeout=30
  wait_for_container "$node" "mongodb" --timeout=30
  wait_for_port "$node" "27017" --timeout=15
done

# Check if the systemd service is active
echo ""
echo "Checking systemd service status..."
for node in $TARGET; do
  assert_service_active "$node" "podman-mongodb" || show_service_logs "$node" "podman-mongodb" 30
done

# Check if container is running
echo ""
echo "Checking container status..."
for node in $TARGET; do
  assert_container_running "$node" "mongodb" "MongoDB container"
done

# Check if MongoDB port is listening
echo ""
echo "Checking MongoDB port (27017)..."
for node in $TARGET; do
  assert_port_listening "$node" "27017" "MongoDB port 27017"
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 4: Running functional tests..."
echo ""

# Detect which mongo shell is available (mongosh for 5+, mongo for 4.x)
get_mongo_shell() {
  local node=$1
  if cmd "$node" "podman exec mongodb which mongosh" > /dev/null 2>&1; then
    echo "mongosh"
  else
    echo "mongo"
  fi
}

# Test MongoDB connection and basic operations
for node in $TARGET; do
  echo "Testing MongoDB operations on $node..."
  
  # Detect shell
  MONGO_SHELL=$(get_mongo_shell "$node")
  print_info "Using shell" "$MONGO_SHELL"
  
  # Insert a test document
  echo "  Inserting test document..."
  insert_result=$(cmd_clean "$node" "podman exec mongodb $MONGO_SHELL --quiet --eval 'db.test.insertOne({name: \"test\", value: 42})'")
  if [[ "$insert_result" == *"acknowledged"* ]] || [[ "$insert_result" == *"insertedId"* ]]; then
    echo -e "  ${GREEN}✓${NC} Insert operation successful [pass]"
  else
    echo -e "  ${RED}✗${NC} Insert operation failed: $insert_result [fail]"
  fi
  
  # Query the test document
  echo "  Querying test document..."
  query_result=$(cmd_clean "$node" "podman exec mongodb $MONGO_SHELL --quiet --eval 'db.test.findOne({name: \"test\"})'")
  assert_contains_all "$query_result" "Query operation successful" "value" "42"
  
  # Test database listing
  echo "  Listing databases..."
  db_list=$(cmd_clean "$node" "podman exec mongodb $MONGO_SHELL --quiet --eval 'db.adminCommand({listDatabases: 1}).databases.map(d => d.name)'")
  assert_contains "$db_list" "admin" "Database listing successful"
  
  # Clean up test data
  echo "  Cleaning up test data..."
  cmd "$node" "podman exec mongodb $MONGO_SHELL --quiet --eval 'db.test.drop()'" > /dev/null 2>&1
  print_cleanup "Test data cleaned up"
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "MongoDB Test Summary"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "MongoDB Test Complete"
echo "========================================"