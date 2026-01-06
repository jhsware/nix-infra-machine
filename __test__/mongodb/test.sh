#!/usr/bin/env bash
# MongoDB standalone test for nix-infra-machine
#
# This test:
# 1. Deploys MongoDB as a native service on custom port 27018
# 2. Verifies the service is running
# 3. Tests basic MongoDB operations (insert/query)
# 4. Cleans up on teardown

# Custom port for testing
MONGODB_PORT=27018

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down MongoDB test..."
  
  # Stop MongoDB service
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop mongodb 2>/dev/null || true'
  
  # Clean up data directory
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/mongodb'
  
  echo "MongoDB teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "MongoDB Standalone Test (port $MONGODB_PORT)"
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

# Wait for service and database to be ready
for node in $TARGET; do
  wait_for_service "$node" "mongodb" --timeout=30
  wait_for_port "$node" "$MONGODB_PORT" --timeout=15
  wait_for_mongodb "$node" "$MONGODB_PORT" --timeout=30
done

# Check if the systemd service is active
echo ""
echo "Checking systemd service status..."
for node in $TARGET; do
  assert_service_active "$node" "mongodb" || show_service_logs "$node" "mongodb" 30
done

# Check if MongoDB process is running
echo ""
echo "Checking MongoDB process..."
for node in $TARGET; do
  assert_process_running "$node" "mongod" "MongoDB"
done

# Check if MongoDB port is listening
echo ""
echo "Checking MongoDB port ($MONGODB_PORT)..."
for node in $TARGET; do
  assert_port_listening "$node" "$MONGODB_PORT" "MongoDB port $MONGODB_PORT"
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 4: Running functional tests..."
echo ""

# Test MongoDB connection and basic operations
for node in $TARGET; do
  echo "Testing MongoDB operations on $node..."
  
  # Insert a test document
  echo "  Inserting test document..."
  insert_result=$(cmd_clean "$node" "mongosh --port $MONGODB_PORT --quiet --eval 'db.test.insertOne({name: \"test\", value: 42})'")
  if [[ "$insert_result" == *"acknowledged"* ]] || [[ "$insert_result" == *"insertedId"* ]]; then
    echo -e "  ${GREEN}✓${NC} Insert operation successful [pass]"
  else
    echo -e "  ${RED}✗${NC} Insert operation failed: $insert_result [fail]"
  fi
  
  # Query the test document
  echo "  Querying test document..."
  query_result=$(cmd_clean "$node" "mongosh --port $MONGODB_PORT --quiet --eval 'db.test.findOne({name: \"test\"})'")
  assert_contains_all "$query_result" "Query operation successful" "value" "42"
  
  # Test database listing
  echo "  Listing databases..."
  db_list=$(cmd_clean "$node" "mongosh --port $MONGODB_PORT --quiet --eval 'db.adminCommand({listDatabases: 1}).databases.map(d => d.name)'")
  assert_contains "$db_list" "admin" "Database listing successful"
  
  # Clean up test data
  echo "  Cleaning up test data..."
  cmd "$node" "mongosh --port $MONGODB_PORT --quiet --eval 'db.test.drop()'" > /dev/null 2>&1
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