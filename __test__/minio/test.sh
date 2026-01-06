#!/usr/bin/env bash
# MinIO standalone test for nix-infra-machine
#
# This test:
# 1. Creates MinIO credentials secret on target nodes
# 2. Deploys MinIO as a native service on custom ports 9002/9003
# 3. Verifies the service is running
# 4. Tests basic MinIO operations (bucket/object operations)
# 5. Cleans up on teardown

# Custom ports for testing
MINIO_API_PORT=9002
MINIO_CONSOLE_PORT=9003
MINIO_USER="testadmin"
MINIO_PASSWORD="testpassword123"
MINIO_SECRET_NAME="minio-root-credentials"

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down MinIO test..."
  
  # Stop MinIO service
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop minio 2>/dev/null || true'
  
  # Clean up data directory
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/minio'
  
  # Clean up secrets
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    "rm -f /run/secrets/$MINIO_SECRET_NAME"
  
  echo "MinIO teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "MinIO Standalone Test (API: $MINIO_API_PORT, Console: $MINIO_CONSOLE_PORT)"
echo "========================================"
echo ""

# Create MinIO credentials secret on target nodes
echo "Step 1: Creating MinIO credentials secret on nodes..."
$NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
  "mkdir -p /run/secrets && cat > /run/secrets/$MINIO_SECRET_NAME << 'EOF'
MINIO_ROOT_USER=$MINIO_USER
MINIO_ROOT_PASSWORD=$MINIO_PASSWORD
EOF"

# Verify secret was created
echo "Verifying secret creation..."
for node in $TARGET; do
  secret_check=$(cmd "$node" "cat /run/secrets/$MINIO_SECRET_NAME 2>/dev/null | head -1")
  assert_contains "$secret_check" "MINIO_ROOT_USER" "Secret created on $node"
done

# Deploy the minio configuration to test nodes
echo ""
echo "Step 2: Deploying MinIO configuration..."
$NIX_INFRA fleet deploy-apps -d "$WORK_DIR" --batch --env="$ENV" \
  --test-dir="$WORK_DIR/$TEST_DIR" \
  --target="$TARGET"

# Apply the configuration
echo "Step 3: Applying NixOS configuration..."
$NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" "nixos-rebuild switch --fast"

# Restart minio to pick up the secret
echo "Restarting MinIO service to pick up secret..."
$NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" "systemctl restart minio"

_setup=$(date +%s)

# ============================================================================
# Test Verification
# ============================================================================

echo ""
echo "Step 4: Verifying MinIO deployment..."
echo ""

# Wait for service and ports to be ready
for node in $TARGET; do
  wait_for_service "$node" "minio" --timeout=30
  wait_for_port "$node" "$MINIO_API_PORT" --timeout=15
  wait_for_port "$node" "$MINIO_CONSOLE_PORT" --timeout=15
  wait_for_http "$node" "http://127.0.0.1:$MINIO_API_PORT/minio/health/live" "200" --timeout=30
done

# Check if the systemd service is active
echo ""
echo "Checking systemd service status..."
for node in $TARGET; do
  assert_service_active "$node" "minio" || show_service_logs "$node" "minio" 50
done

# Check if MinIO process is running
echo ""
echo "Checking MinIO process..."
for node in $TARGET; do
  assert_process_running "$node" "minio" "MinIO"
done

# Check if MinIO API port is listening
echo ""
echo "Checking MinIO API port ($MINIO_API_PORT)..."
for node in $TARGET; do
  assert_port_listening "$node" "$MINIO_API_PORT" "API port $MINIO_API_PORT"
done

# Check if MinIO Console port is listening
echo ""
echo "Checking MinIO Console port ($MINIO_CONSOLE_PORT)..."
for node in $TARGET; do
  assert_port_listening "$node" "$MINIO_CONSOLE_PORT" "Console port $MINIO_CONSOLE_PORT"
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 5: Running functional tests..."
echo ""

# Test MinIO connection and basic operations
for node in $TARGET; do
  echo "Testing MinIO operations on $node..."
  
  # Configure mc (MinIO client) alias
  echo "  Configuring MinIO client..."
  mc_config=$(cmd_clean "$node" "mc alias set testminio http://127.0.0.1:$MINIO_API_PORT $MINIO_USER $MINIO_PASSWORD 2>&1")
  if [[ "$mc_config" == *"successfully"* ]] || [[ "$mc_config" == *"Added"* ]] || [[ -z "$mc_config" ]]; then
    echo -e "  ${GREEN}✓${NC} MinIO client configured [pass]"
  else
    echo -e "  ${RED}✗${NC} MinIO client configuration failed: $mc_config [fail]"
  fi
  
  # Test server health endpoint using HTTP status code
  echo "  Checking server health..."
  assert_http_status "$node" "http://127.0.0.1:$MINIO_API_PORT/minio/health/live" "200" "Server health endpoint"
  
  # Create a test bucket
  echo "  Creating test bucket..."
  bucket_result=$(cmd_clean "$node" "mc mb testminio/test-bucket 2>&1")
  if [[ "$bucket_result" == *"Bucket created successfully"* ]] || [[ "$bucket_result" == *"created"* ]]; then
    echo -e "  ${GREEN}✓${NC} Bucket creation successful [pass]"
  else
    echo -e "  ${RED}✗${NC} Bucket creation failed: $bucket_result [fail]"
  fi
  
  # List buckets
  echo "  Listing buckets..."
  list_result=$(cmd_clean "$node" "mc ls testminio 2>&1")
  assert_contains "$list_result" "test-bucket" "Bucket listing successful"
  
  # Upload a test object
  echo "  Uploading test object..."
  cmd "$node" "echo 'Hello MinIO Test!' > /tmp/test-file.txt"
  upload_result=$(cmd_clean "$node" "mc cp /tmp/test-file.txt testminio/test-bucket/test-file.txt 2>&1")
  if [[ "$upload_result" == *"test-file.txt"* ]] || [[ -z "$upload_result" ]]; then
    echo -e "  ${GREEN}✓${NC} Object upload successful [pass]"
  else
    echo -e "  ${RED}✗${NC} Object upload failed: $upload_result [fail]"
  fi
  
  # List objects in bucket
  echo "  Listing objects in bucket..."
  objects_result=$(cmd_clean "$node" "mc ls testminio/test-bucket 2>&1")
  assert_contains "$objects_result" "test-file.txt" "Object listing successful"
  
  # Download the test object
  echo "  Downloading test object..."
  cmd "$node" "rm -f /tmp/downloaded-file.txt"
  download_result=$(cmd_clean "$node" "mc cp testminio/test-bucket/test-file.txt /tmp/downloaded-file.txt 2>&1")
  content_check=$(cmd_clean "$node" "cat /tmp/downloaded-file.txt 2>/dev/null")
  assert_contains "$content_check" "Hello MinIO Test!" "Object download successful"
  
  # Get object info/stat
  echo "  Getting object info..."
  stat_result=$(cmd_clean "$node" "mc stat testminio/test-bucket/test-file.txt 2>&1")
  if [[ "$stat_result" == *"test-file.txt"* ]] || [[ "$stat_result" == *"Size"* ]]; then
    echo -e "  ${GREEN}✓${NC} Object stat successful [pass]"
  else
    echo -e "  ${RED}✗${NC} Object stat failed: $stat_result [fail]"
  fi
  
  # Clean up - remove object
  echo "  Cleaning up test object..."
  cmd "$node" "mc rm testminio/test-bucket/test-file.txt 2>&1" > /dev/null
  print_cleanup "Test object removed"
  
  # Clean up - remove bucket
  echo "  Cleaning up test bucket..."
  cmd "$node" "mc rb testminio/test-bucket 2>&1" > /dev/null
  print_cleanup "Test bucket removed"
  
  # Clean up temp files
  cmd "$node" "rm -f /tmp/test-file.txt /tmp/downloaded-file.txt" > /dev/null 2>&1
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "MinIO Test Summary"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "MinIO Test Complete"
echo "========================================"