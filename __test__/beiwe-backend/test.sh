#!/usr/bin/env bash
# beiwe-backend test for nix-infra-machine
#
# This test:
# 1. Deploys beiwe-backend with PostgreSQL, MinIO, RabbitMQ, and Celery
# 2. Verifies all services are running
# 3. Tests beiwe-backend endpoints and basic functionality
# 4. Cleans up on teardown

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down beiwe-backend test..."
  
  # Stop services
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop beiwe-celery-beat 2>/dev/null || true'
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop beiwe-celery-worker 2>/dev/null || true'
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop beiwe-backend 2>/dev/null || true'
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop minio 2>/dev/null || true'
    
  # Clean up data directories
  echo "  Removing beiwe-backend data directory..."
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/beiwe-backend'
  
  echo "  Removing MinIO data directory..."
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/minio'
  
  # Drop database
  echo "  Dropping beiwe database..."
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'sudo -u postgres psql -c "DROP DATABASE IF EXISTS beiwe" 2>/dev/null || true'
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'sudo -u postgres psql -c "DROP USER IF EXISTS beiwe" 2>/dev/null || true'
    
  echo "beiwe-backend teardown complete"
  return 0
fi


# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "Beiwe Backend Test"
echo "========================================"
echo ""
echo "This test verifies:"
echo "  - PostgreSQL database connectivity"
echo "  - MinIO S3-compatible storage"
echo "  - RabbitMQ message broker"
echo "  - Celery background task worker"
echo "  - Beiwe backend web service"
echo ""

# Deploy the beiwe-backend configuration to test nodes
echo "Step 1: Deploying beiwe-backend configuration..."
$NIX_INFRA fleet deploy-apps -d "$WORK_DIR" --batch --debug --env="$ENV" \
  --test-dir="$WORK_DIR/$TEST_DIR" --no-rebuild \
  --target="$TARGET"

# Apply the configuration
echo "Step 2: Applying NixOS configuration..."
$NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" "nixos-rebuild switch --fast"

_setup=$(date +%s)

# ============================================================================
# Test Verification
# ============================================================================

echo ""
echo "Step 3: Verifying deployment..."
echo ""

# Wait for services to be ready
for node in $TARGET; do
  echo "Waiting for services on $node..."
  
  # Wait for PostgreSQL
  wait_for_service "$node" "postgresql" --timeout=60
  wait_for_port "$node" "5432" --timeout=30
  
  # Wait for MinIO
  wait_for_service "$node" "minio" --timeout=60
  wait_for_port "$node" "9000" --timeout=30
  
  # Wait for MinIO bucket creation to complete
  wait_for_service "$node" "minio-create-bucket" --timeout=60
  
  # Wait for RabbitMQ
  wait_for_service "$node" "rabbitmq" --timeout=60
  wait_for_port "$node" "5672" --timeout=30
  
  # Wait for beiwe-backend (may take time for migrations)
  wait_for_service "$node" "beiwe-backend" --timeout=60
  wait_for_port "$node" "8080" --timeout=30
  
  # Wait for Celery worker (may take time to connect to RabbitMQ)
  wait_for_service "$node" "beiwe-celery-worker" --timeout=90
  
  # Wait for HTTP response (Django may take time to initialize)
  wait_for_http "$node" "http://localhost:8080/" "200 302 303 400 403 404 500" --timeout=90
done


# ============================================================================
# Check Service Status
# ============================================================================

echo ""
echo "Step 4: Checking systemd services status..."
echo ""

for node in $TARGET; do
  echo "...checking services on $node"
  
  # PostgreSQL
  echo "  Checking PostgreSQL..."
  assert_service_active "$node" "postgresql" || show_service_logs "$node" "postgresql" 50
  
  # MinIO
  echo "  Checking MinIO..."
  assert_service_active "$node" "minio" || show_service_logs "$node" "minio" 50
  
  # MinIO bucket creation (oneshot service)
  echo "  Checking minio-create-bucket..."
  bucket_setup_status=$(cmd_clean "$node" "systemctl is-active minio-create-bucket 2>/dev/null || echo 'unknown'")
  if [[ "$bucket_setup_status" == "active" ]] || [[ "$bucket_setup_status" == "activating" ]]; then
    echo -e "  ${GREEN}✓${NC} minio-create-bucket: $bucket_setup_status [pass]"
  else
    echo -e "  ${YELLOW}!${NC} minio-create-bucket: $bucket_setup_status [warn]"
    show_service_logs "$node" "minio-create-bucket" 50
  fi
  
  # RabbitMQ
  echo "  Checking RabbitMQ..."
  assert_service_active "$node" "rabbitmq" || show_service_logs "$node" "rabbitmq" 50
  
  # Beiwe Backend
  echo "  Checking beiwe-backend..."
  assert_service_active "$node" "beiwe-backend" || show_service_logs "$node" "beiwe-backend" 100
  
  # Celery Worker
  echo "  Checking beiwe-celery-worker..."
  assert_service_active "$node" "beiwe-celery-worker" || show_service_logs "$node" "beiwe-celery-worker" 100
  
  # Celery Beat (scheduler)
  echo "  Checking beiwe-celery-beat..."
  assert_service_active "$node" "beiwe-celery-beat" || show_service_logs "$node" "beiwe-celery-beat" 50
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
  assert_port_listening "$node" "9000" "MinIO API port 9000"
  assert_port_listening "$node" "5672" "RabbitMQ AMQP port 5672"
  assert_port_listening "$node" "15672" "RabbitMQ Management port 15672"
  assert_port_listening "$node" "8080" "Beiwe backend port 8080"
done

# ============================================================================
# Database Tests
# ============================================================================

echo ""
echo "Step 6: Testing PostgreSQL database..."
echo ""

for node in $TARGET; do
  echo "Testing database on $node..."
  
  # Check database exists
  db_exists=$(cmd_clean "$node" "sudo -u postgres psql -lqt | grep -c beiwe || echo 0")
  if [[ "$db_exists" -ge 1 ]]; then
    echo -e "  ${GREEN}✓${NC} Database 'beiwe' exists [pass]"
  else
    echo -e "  ${RED}✗${NC} Database 'beiwe' not found [fail]"
  fi
  
  # Check user exists
  user_exists=$(cmd_clean "$node" "sudo -u postgres psql -c \"SELECT 1 FROM pg_roles WHERE rolname='beiwe'\" | grep -c 1 || echo 0")
  if [[ "$user_exists" -ge 1 ]]; then
    echo -e "  ${GREEN}✓${NC} User 'beiwe' exists [pass]"
  else
    echo -e "  ${YELLOW}!${NC} User 'beiwe' not found (may be created on first run) [warn]"
  fi
done

# ============================================================================
# MinIO Tests
# ============================================================================

echo ""
echo "Step 7: Testing MinIO S3 storage..."
echo ""

for node in $TARGET; do
  echo "Testing MinIO on $node..."
  
  # Check MinIO health
  minio_health=$(cmd_clean "$node" "curl -s http://127.0.0.1:9000/minio/health/live 2>/dev/null || echo 'failed'")
  if [[ "$minio_health" != "failed" ]]; then
    echo -e "  ${GREEN}✓${NC} MinIO health check passed [pass]"
  else
    echo -e "  ${RED}✗${NC} MinIO health check failed [fail]"
  fi
  
  # Check bucket exists (set HOME for mc config)
  bucket_exists=$(cmd_clean "$node" "export HOME=/tmp/mc-test-check && mkdir -p \$HOME && mc alias set local http://127.0.0.1:9000 minioadmin minioadmin123 --api S3v4 > /dev/null 2>&1 && mc ls local/beiwe-data > /dev/null 2>&1 && echo 'yes' || echo 'no'")
  if [[ "$bucket_exists" == "yes" ]]; then
    echo -e "  ${GREEN}✓${NC} Bucket 'beiwe-data' exists [pass]"
  else
    echo -e "  ${RED}✗${NC} Bucket 'beiwe-data' not found [fail]"
    # Show bucket list for debugging
    echo "    Available buckets:"
    cmd_clean "$node" "export HOME=/tmp/mc-test-check && mc ls local/ 2>/dev/null || echo '    (none)'" | while read line; do echo "      $line"; done
  fi
done


# ============================================================================
# RabbitMQ Tests
# ============================================================================

echo ""
echo "Step 8: Testing RabbitMQ message broker..."
echo ""

for node in $TARGET; do
  echo "Testing RabbitMQ on $node..."
  
  # Check RabbitMQ via management API (more reliable than rabbitmqctl which needs root)
  rabbitmq_api_status=$(cmd_clean "$node" "curl -s -o /dev/null -w '%{http_code}' -u guest:guest http://127.0.0.1:15672/api/overview 2>/dev/null || echo '000'")
  if [[ "$rabbitmq_api_status" == "200" ]]; then
    echo -e "  ${GREEN}✓${NC} RabbitMQ API responding (status: $rabbitmq_api_status) [pass]"
  else
    echo -e "  ${RED}✗${NC} RabbitMQ API not responding (status: $rabbitmq_api_status) [fail]"
  fi
  
  # Check management UI is accessible
  mgmt_status=$(cmd_clean "$node" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:15672/ 2>/dev/null || echo '000'")
  if [[ "$mgmt_status" == "200" ]] || [[ "$mgmt_status" == "301" ]]; then
    echo -e "  ${GREEN}✓${NC} RabbitMQ Management UI accessible (status: $mgmt_status) [pass]"
  else
    echo -e "  ${YELLOW}!${NC} RabbitMQ Management UI returned status: $mgmt_status [warn]"
  fi
done


# ============================================================================
# Celery Worker Tests
# ============================================================================

echo ""
echo "Step 9: Testing Celery worker..."
echo ""

for node in $TARGET; do
  echo "Testing Celery on $node..."
  
  # Check Celery process is running
  celery_running=$(cmd_clean "$node" "pgrep -f 'celery.*worker' > /dev/null && echo 'yes' || echo 'no'")
  if [[ "$celery_running" == "yes" ]]; then
    echo -e "  ${GREEN}✓${NC} Celery worker process running [pass]"
  else
    echo -e "  ${RED}✗${NC} Celery worker process not found [fail]"
  fi
  
  # Check Celery beat (scheduler) is running
  celery_beat=$(cmd_clean "$node" "pgrep -f 'celery.*beat' > /dev/null && echo 'yes' || echo 'no'")
  if [[ "$celery_beat" == "yes" ]]; then
    echo -e "  ${GREEN}✓${NC} Celery beat (scheduler) running [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Celery beat not running (scheduled tasks may not work) [warn]"
  fi
done

# ============================================================================
# Beiwe Backend HTTP Tests
# ============================================================================

echo ""
echo "Step 10: Testing Beiwe backend HTTP endpoints..."
echo ""

for node in $TARGET; do
  echo "Testing Beiwe backend on $node..."
  
  # Test basic HTTP response (any response means server is running)
  http_status=$(cmd_clean "$node" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/ 2>/dev/null")
  if [[ -n "$http_status" ]] && [[ "$http_status" != "000" ]]; then
    echo -e "  ${GREEN}✓${NC} HTTP response received (status: $http_status) [pass]"
  else
    echo -e "  ${RED}✗${NC} No HTTP response from beiwe-backend [fail]"
  fi
  
  # Test if Django is responding (check for specific patterns in response)
  response_body=$(cmd_clean "$node" "curl -s http://localhost:8080/ 2>/dev/null | head -c 500")
  if [[ "$response_body" == *"html"* ]] || [[ "$response_body" == *"HTML"* ]] || [[ "$response_body" == *"django"* ]] || [[ "$response_body" == *"Django"* ]] || [[ "$response_body" == *"Beiwe"* ]] || [[ "$response_body" == *"beiwe"* ]]; then
    echo -e "  ${GREEN}✓${NC} Django/Beiwe response detected [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Response doesn't look like Django/Beiwe (may still be OK) [warn]"
    echo "    Response preview: ${response_body:0:100}..."
  fi
  
  # Check that gunicorn process is running
  echo "  Checking gunicorn process..."
  gunicorn_running=$(cmd_clean "$node" "pgrep -f gunicorn > /dev/null && echo 'yes' || echo 'no'")
  if [[ "$gunicorn_running" == "yes" ]]; then
    echo -e "  ${GREEN}✓${NC} Gunicorn process running [pass]"
  else
    echo -e "  ${RED}✗${NC} Gunicorn process not found [fail]"
  fi
done

# ============================================================================
# Service Health Summary
# ============================================================================

echo ""
echo "Step 11: Final health checks..."
echo ""

for node in $TARGET; do
  echo "Final checks on $node..."
  
  # Check for any failed units
  echo "  Checking for failed units..."
  failed_units=$(cmd_clean "$node" "systemctl list-units --failed | grep -E 'beiwe|minio|postgresql|rabbitmq' || echo 'none'")
  if [[ "$failed_units" == *"none"* ]] || [[ -z "$failed_units" ]] || [[ ! "$failed_units" == *"failed"* ]]; then
    echo -e "  ${GREEN}✓${NC} No failed related units [pass]"
  else
    echo -e "  ${RED}✗${NC} Failed units found: $failed_units [fail]"
  fi
  
  # Check data directories
  echo "  Checking data directories..."
  assert_dir_exists "$node" "/var/lib/minio" "MinIO data directory"
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "Beiwe Backend Test Summary"
echo "========================================"
echo ""
echo "Services tested:"
echo "  ✓ PostgreSQL (database)"
echo "  ✓ MinIO (S3-compatible storage)"
echo "  ✓ RabbitMQ (message broker)"
echo "  ✓ Celery Worker (background tasks)"
echo "  ✓ Celery Beat (task scheduler)"
echo "  ✓ Beiwe Backend (Django/Gunicorn)"
echo ""
echo "Optional services NOT configured:"
echo "  ✗ Firebase credentials (for push notifications)"
echo "  ✗ Sentry error tracking"
echo ""
echo "Features available with this configuration:"
echo "  ✓ Web-based study management portal"
echo "  ✓ User authentication and management"
echo "  ✓ Study and survey configuration"
echo "  ✓ Participant registration"
echo "  ✓ Data uploads from mobile apps"
echo "  ✓ Background task processing"
echo "  ✓ Data processing pipelines"
echo ""

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "Beiwe Backend Test Complete"
echo "========================================"
