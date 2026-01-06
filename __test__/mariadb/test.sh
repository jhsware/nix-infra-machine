#!/usr/bin/env bash
# MariaDB standalone test for nix-infra-machine
#
# This test:
# 1. Deploys MariaDB as a native service
# 2. Verifies the service is running
# 3. Tests basic MariaDB operations (create table, insert, query)
# 4. Cleans up on teardown

# MariaDB port
MARIADB_PORT=3306

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down MariaDB test..."
  
  # Stop MariaDB service
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop mysql 2>/dev/null || true'
  
  # Clean up data directory
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/mysql'
  
  echo "MariaDB teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "MariaDB Standalone Test (port $MARIADB_PORT)"
echo "========================================"
echo ""

# Deploy the mariadb configuration to test nodes
echo "Step 1: Deploying MariaDB configuration..."
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
echo "Step 3: Verifying MariaDB deployment..."
echo ""

# Wait for service and port to be ready
for node in $TARGET; do
  wait_for_service "$node" "mysql" --timeout=30
  wait_for_port "$node" "$MARIADB_PORT" --timeout=15
done

# Check if the systemd service is active
echo ""
echo "Checking systemd service status..."
for node in $TARGET; do
  assert_service_active "$node" "mysql" || show_service_logs "$node" "mysql" 30
done

# Check if MariaDB process is running
echo ""
echo "Checking MariaDB process..."
for node in $TARGET; do
  process_status=$(cmd_clean "$node" "pgrep -a mariadbd || pgrep -a mysqld")
  assert_not_empty "$process_status" "MariaDB process running"
done

# Check if MariaDB port is listening
echo ""
echo "Checking MariaDB port ($MARIADB_PORT)..."
for node in $TARGET; do
  assert_port_listening "$node" "$MARIADB_PORT" "MariaDB port $MARIADB_PORT"
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 4: Running functional tests..."
echo ""

# Test MariaDB connection and basic operations
for node in $TARGET; do
  echo "Testing MariaDB operations on $node..."
  
  # Test connection
  echo "  Testing connection..."
  conn_result=$(cmd_clean "$node" "mysql -u root -e 'SELECT 1 as test;' 2>&1")
  assert_contains "$conn_result" "1" "Connection successful"
  
  # Check if testdb was created
  echo "  Checking testdb database..."
  db_check=$(cmd_clean "$node" "mysql -u root -e 'SHOW DATABASES;' | grep testdb")
  assert_contains "$db_check" "testdb" "Database 'testdb' exists"
  
  # Create a test table
  echo "  Creating test table..."
  create_result=$(cmd_clean "$node" "mysql -u root -D testdb -e 'CREATE TABLE IF NOT EXISTS test_table (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100), value INT);' 2>&1")
  assert_no_error "$create_result" "Create table successful"
  
  # Insert a test record
  echo "  Inserting test record..."
  insert_result=$(cmd_clean "$node" "mysql -u root -D testdb -e \"INSERT INTO test_table (name, value) VALUES ('test', 42);\" 2>&1")
  assert_no_error "$insert_result" "Insert operation successful"
  
  # Query the test record
  echo "  Querying test record..."
  query_result=$(cmd_clean "$node" "mysql -u root -D testdb -e \"SELECT * FROM test_table WHERE name = 'test';\" 2>&1")
  assert_contains_all "$query_result" "Query operation successful" "test" "42"
  
  # Test database listing
  echo "  Listing databases..."
  db_list=$(cmd_clean "$node" "mysql -u root -e 'SHOW DATABASES;' 2>&1")
  assert_contains_all "$db_list" "Database listing successful" "mysql" "information_schema"
  
  # Test user was created
  echo "  Checking testuser exists..."
  user_check=$(cmd_clean "$node" "mysql -u root -e \"SELECT User FROM mysql.user WHERE User='testuser';\" 2>&1")
  assert_contains "$user_check" "testuser" "User 'testuser' exists"
  
  # Clean up test data
  echo "  Cleaning up test data..."
  cmd "$node" "mysql -u root -D testdb -e 'DROP TABLE IF EXISTS test_table;'" > /dev/null 2>&1
  print_cleanup "Test data cleaned up"
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "MariaDB Test Summary"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "MariaDB Test Complete"
echo "========================================"