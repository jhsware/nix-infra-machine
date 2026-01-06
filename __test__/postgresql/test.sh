#!/usr/bin/env bash
# PostgreSQL standalone test for nix-infra-machine
#
# This test:
# 1. Deploys PostgreSQL as a native service
# 2. Verifies the service is running
# 3. Tests basic PostgreSQL operations (create table, insert, query)
# 4. Cleans up on teardown

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down PostgreSQL test..."
  
  # Stop PostgreSQL service
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop postgresql 2>/dev/null || true'
  
  # Clean up data directory
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/postgresql'
  
  echo "PostgreSQL teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "PostgreSQL Standalone Test"
echo "========================================"
echo ""

# Deploy the postgresql configuration to test nodes
echo "Step 1: Deploying PostgreSQL configuration..."
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
echo "Step 3: Verifying PostgreSQL deployment..."
echo ""

# Wait for service and database to be ready
for node in $TARGET; do
  wait_for_service "$node" "postgresql" --timeout=30
  wait_for_port "$node" "5432" --timeout=15
  wait_for_postgresql "$node" --timeout=30
done

# Check if the systemd service is active
echo ""
echo "Checking systemd service status..."
for node in $TARGET; do
  assert_service_active "$node" "postgresql" || show_service_logs "$node" "postgresql" 30
done

# Check if PostgreSQL process is running
echo ""
echo "Checking PostgreSQL process..."
for node in $TARGET; do
  assert_process_running "$node" "postgres" "PostgreSQL"
done

# Check if PostgreSQL port is listening
echo ""
echo "Checking PostgreSQL port (5432)..."
for node in $TARGET; do
  assert_port_listening "$node" "5432" "PostgreSQL port 5432"
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 4: Running functional tests..."
echo ""

# Test PostgreSQL connection and basic operations
for node in $TARGET; do
  echo "Testing PostgreSQL operations on $node..."
  
  # Test connection
  echo "  Testing connection..."
  conn_result=$(cmd_clean "$node" "sudo -u postgres psql -c 'SELECT 1 as test;' 2>&1")
  assert_contains "$conn_result" "1" "Connection successful"
  
  # Check if testdb was created
  echo "  Checking testdb database..."
  db_check=$(cmd_clean "$node" "sudo -u postgres psql -l | grep testdb")
  assert_contains "$db_check" "testdb" "Database 'testdb' exists"
  
  # Create a test table
  echo "  Creating test table..."
  create_result=$(cmd_clean "$node" "sudo -u postgres psql -d testdb -c 'CREATE TABLE IF NOT EXISTS test_table (id SERIAL PRIMARY KEY, name VARCHAR(100), value INTEGER);' 2>&1")
  if [[ "$create_result" == *"CREATE TABLE"* ]] || [[ "$create_result" == *"already exists"* ]] || [[ -z "$create_result" ]]; then
    echo -e "  ${GREEN}✓${NC} Create table successful [pass]"
  else
    echo -e "  ${RED}✗${NC} Create table failed: $create_result [fail]"
  fi
  
  # Insert a test record
  echo "  Inserting test record..."
  insert_result=$(cmd_clean "$node" "sudo -u postgres psql -d testdb -c \"INSERT INTO test_table (name, value) VALUES ('test', 42);\" 2>&1")
  assert_contains "$insert_result" "INSERT" "Insert operation successful"
  
  # Query the test record
  echo "  Querying test record..."
  query_result=$(cmd_clean "$node" "sudo -u postgres psql -d testdb -c 'SELECT * FROM test_table WHERE name = '\\''test'\\'';' 2>&1")
  assert_contains_all "$query_result" "Query operation successful" "test" "42"
  
  # Test database listing
  echo "  Listing databases..."
  db_list=$(cmd_clean "$node" "sudo -u postgres psql -c '\\l' 2>&1")
  assert_contains "$db_list" "postgres" "Database listing successful"
  
  # Clean up test data
  echo "  Cleaning up test data..."
  cmd "$node" "sudo -u postgres psql -d testdb -c 'DROP TABLE IF EXISTS test_table;'" > /dev/null 2>&1
  print_cleanup "Test data cleaned up"
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "PostgreSQL Test Summary"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "PostgreSQL Test Complete"
echo "========================================"