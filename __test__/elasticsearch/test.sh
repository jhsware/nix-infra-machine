#!/usr/bin/env bash
# Elasticsearch standalone test for nix-infra-machine
#
# This test:
# 1. Deploys Elasticsearch as a native service on custom port 9202
# 2. Verifies the service is running
# 3. Tests basic Elasticsearch operations (index/query)
# 4. Cleans up on teardown

# Custom ports for testing
ELASTICSEARCH_HTTP_PORT=9202
ELASTICSEARCH_TRANSPORT_PORT=9302

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down Elasticsearch test..."
  
  # Stop Elasticsearch service
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop elasticsearch 2>/dev/null || true'
  
  # Clean up data directory
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/elasticsearch'
  
  echo "Elasticsearch teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "Elasticsearch Standalone Test (port $ELASTICSEARCH_HTTP_PORT)"
echo "========================================"
echo ""

# Deploy the elasticsearch configuration to test nodes
echo "Step 1: Deploying Elasticsearch configuration..."
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
echo "Step 3: Verifying Elasticsearch deployment..."
echo ""

# Wait for Elasticsearch service and API to be ready
for node in $TARGET; do
  wait_for_service "$node" "elasticsearch" --timeout=60
  wait_for_port "$node" "$ELASTICSEARCH_HTTP_PORT" --timeout=30
  wait_for_elasticsearch "$node" "$ELASTICSEARCH_HTTP_PORT" --timeout=60
done

# Check if the systemd service is active
echo ""
echo "Checking systemd service status..."
for node in $TARGET; do
  assert_service_active "$node" "elasticsearch" || show_service_logs "$node" "elasticsearch" 50
done

# Check if Elasticsearch process is running
echo ""
echo "Checking Elasticsearch process..."
for node in $TARGET; do
  assert_process_running "$node" "-f elasticsearch" "Elasticsearch"
done

# Check if Elasticsearch HTTP port is listening
echo ""
echo "Checking Elasticsearch HTTP port ($ELASTICSEARCH_HTTP_PORT)..."
for node in $TARGET; do
  assert_port_listening "$node" "$ELASTICSEARCH_HTTP_PORT" "HTTP port $ELASTICSEARCH_HTTP_PORT"
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 4: Running functional tests..."
echo ""

# Test Elasticsearch connection and basic operations
for node in $TARGET; do
  echo "Testing Elasticsearch operations on $node..."
  
  # Test cluster health endpoint
  echo "  Checking cluster health..."
  health_result=$(cmd_clean "$node" "curl -s http://127.0.0.1:$ELASTICSEARCH_HTTP_PORT/_cluster/health")
  if assert_contains "$health_result" "cluster_name" "Cluster health endpoint accessible"; then
    status=$(echo "$health_result" | jq -r '.status' 2>/dev/null || echo "unknown")
    print_info "Cluster status" "$status"
  fi
  
  # Create a test index
  echo "  Creating test index..."
  create_result=$(cmd_clean "$node" "curl -s -X PUT 'http://127.0.0.1:$ELASTICSEARCH_HTTP_PORT/test-index' -H 'Content-Type: application/json' -d '{\"settings\": {\"number_of_shards\": 1, \"number_of_replicas\": 0}}'")
  assert_contains_all "$create_result" "Index creation successful" "acknowledged" "true"
  
  # Insert a test document
  echo "  Inserting test document..."
  insert_result=$(cmd_clean "$node" "curl -s -X POST 'http://127.0.0.1:$ELASTICSEARCH_HTTP_PORT/test-index/_doc/1' -H 'Content-Type: application/json' -d '{\"name\": \"test\", \"value\": 42}'")
  if [[ "$insert_result" == *"created"* ]] || [[ "$insert_result" == *"_id"* ]]; then
    echo -e "  ${GREEN}✓${NC} Document insert successful [pass]"
  else
    echo -e "  ${RED}✗${NC} Document insert failed: $insert_result [fail]"
  fi
  
  # Force refresh to make document searchable
  cmd "$node" "curl -s -X POST 'http://127.0.0.1:$ELASTICSEARCH_HTTP_PORT/test-index/_refresh'" > /dev/null 2>&1
  
  # Query the test document
  echo "  Querying test document..."
  query_result=$(cmd_clean "$node" "curl -s 'http://127.0.0.1:$ELASTICSEARCH_HTTP_PORT/test-index/_doc/1'")
  assert_contains_all "$query_result" "Document query successful" "found" "true"
  
  # Test search functionality
  echo "  Testing search..."
  search_result=$(cmd_clean "$node" "curl -s -X GET 'http://127.0.0.1:$ELASTICSEARCH_HTTP_PORT/test-index/_search' -H 'Content-Type: application/json' -d '{\"query\": {\"match\": {\"name\": \"test\"}}}'")
  assert_contains_all "$search_result" "Search operation successful" "hits" "value"
  
  # List indices
  echo "  Listing indices..."
  indices_result=$(cmd_clean "$node" "curl -s 'http://127.0.0.1:$ELASTICSEARCH_HTTP_PORT/_cat/indices?v'")
  assert_contains "$indices_result" "test-index" "Index listing successful"
  
  # Clean up test index
  echo "  Cleaning up test index..."
  cmd "$node" "curl -s -X DELETE 'http://127.0.0.1:$ELASTICSEARCH_HTTP_PORT/test-index'" > /dev/null 2>&1
  print_cleanup "Test index cleaned up"
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "Elasticsearch Test Summary"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "Elasticsearch Test Complete"
echo "========================================"