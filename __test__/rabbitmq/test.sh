#!/usr/bin/env bash
# RabbitMQ standalone test for nix-infra-machine
#
# This test:
# 1. Deploys RabbitMQ as a native service
# 2. Verifies the service is running
# 3. Tests basic RabbitMQ operations (queue creation, publish/consume)
# 4. Tests the management API
# 5. Cleans up on teardown

# Ports for testing
RABBITMQ_PORT=5672
MANAGEMENT_PORT=15672

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down RabbitMQ test..."
  
  # Stop RabbitMQ service
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop rabbitmq 2>/dev/null || true'
  
  # Clean up data directory
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/rabbitmq'
  
  echo "RabbitMQ teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "RabbitMQ Standalone Test"
echo "  AMQP port: $RABBITMQ_PORT"
echo "  Management port: $MANAGEMENT_PORT"
echo "========================================"
echo ""

# Deploy the rabbitmq configuration to test nodes
echo "Step 1: Deploying RabbitMQ configuration..."
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
echo "Step 3: Verifying RabbitMQ deployment..."
echo ""

# Wait for service and ports to be ready
for node in $TARGET; do
  wait_for_service "$node" "rabbitmq" --timeout=60
  wait_for_port "$node" "$RABBITMQ_PORT" --timeout=30
  wait_for_port "$node" "$MANAGEMENT_PORT" --timeout=30
done

# Check if the systemd service is active
echo ""
echo "Checking systemd service status..."
for node in $TARGET; do
  assert_service_active "$node" "rabbitmq" || show_service_logs "$node" "rabbitmq" 30
done


echo ""
echo "Checking RabbitMQ process..."
for node in $TARGET; do
  assert_process_running "$node" "beam.smp" "RabbitMQ (Erlang VM)"
done

# Check if AMQP port is listening
echo ""
echo "Checking AMQP port ($RABBITMQ_PORT)..."
for node in $TARGET; do
  assert_port_listening "$node" "$RABBITMQ_PORT" "AMQP port $RABBITMQ_PORT"
done

# Check if Management port is listening
echo ""
echo "Checking Management port ($MANAGEMENT_PORT)..."
for node in $TARGET; do
  assert_port_listening "$node" "$MANAGEMENT_PORT" "Management port $MANAGEMENT_PORT"
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 4: Running functional tests..."
echo ""

for node in $TARGET; do
  echo "Testing RabbitMQ operations on $node..."
  
  # Test management API - get overview
  echo "  Testing management API..."
  api_result=$(cmd_clean "$node" "curl -s -u guest:guest http://127.0.0.1:$MANAGEMENT_PORT/api/overview")
  assert_contains "$api_result" "rabbitmq_version" "Management API overview"

  # Test creating a queue via management API

  echo "  Creating test queue..."
  create_result=$(cmd_clean "$node" "curl -s -u guest:guest -X PUT -H 'Content-Type: application/json' \
    -d '{\"durable\":false,\"auto_delete\":false}' \
    http://127.0.0.1:$MANAGEMENT_PORT/api/queues/%2F/test-queue")
  # Empty response or no error means success
  if [[ -z "$create_result" ]] || [[ "$create_result" != *"error"* ]]; then
    echo -e "  ${GREEN}✓${NC} Queue creation successful [pass]"
  else
    echo -e "  ${RED}✗${NC} Queue creation failed: $create_result [fail]"
  fi
  
  # Small delay to ensure queue is ready
  sleep 1
  
  # Test listing queues (do this before publish to verify queue exists)
  echo "  Listing queues..."
  queues_result=$(cmd_clean "$node" "curl -s -u guest:guest http://127.0.0.1:$MANAGEMENT_PORT/api/queues")
  assert_contains "$queues_result" "test-queue" "Queue listing"
  
  # Test listing exchanges
  echo "  Listing exchanges..."
  exchanges_result=$(cmd_clean "$node" "curl -s -u guest:guest http://127.0.0.1:$MANAGEMENT_PORT/api/exchanges")
  assert_contains "$exchanges_result" "amq.direct" "Exchange listing"
  
  # Test publishing a message
  echo "  Publishing test message..."
  publish_result=$(cmd_clean "$node" "curl -s -u guest:guest -X POST -H 'Content-Type: application/json' \
    -d '{\"properties\":{},\"routing_key\":\"test-queue\",\"payload\":\"HelloRabbitMQ\",\"payload_encoding\":\"string\"}' \
    http://127.0.0.1:$MANAGEMENT_PORT/api/exchanges/%2F/amq.default/publish")
  assert_contains "$publish_result" "routed" "Message publish"
  
  # Small delay to ensure message is available
  sleep 1
  
  # Test getting messages from the queue
  echo "  Consuming test message..."
  consume_result=$(cmd_clean "$node" "curl -s -u guest:guest -X POST -H 'Content-Type: application/json' \
    -d '{\"count\":1,\"ackmode\":\"ack_requeue_false\",\"encoding\":\"auto\"}' \
    http://127.0.0.1:$MANAGEMENT_PORT/api/queues/%2F/test-queue/get")
  assert_contains "$consume_result" "HelloRabbitMQ" "Message consume"
  
  # Clean up test queue
  echo "  Cleaning up test queue..."
  cmd "$node" "curl -s -u guest:guest -X DELETE http://127.0.0.1:$MANAGEMENT_PORT/api/queues/%2F/test-queue" > /dev/null 2>&1
  print_cleanup "Test queue deleted"
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "RabbitMQ Test Summary"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "RabbitMQ Test Complete"
echo "========================================"
