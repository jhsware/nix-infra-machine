#!/usr/bin/env bash
# n8n test for nix-infra-machine
#
# This test:
# 1. Deploys n8n with SQLite backend
# 2. Verifies all services are running
# 3. Tests n8n endpoints and REST API functionality
# 4. Cleans up on teardown

# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down n8n test..."
  
  # Stop services
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop n8n 2>/dev/null || true'
    
  # Clean up entire n8n data directory including SQLite database
  echo "  Removing n8n data directory..."
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/n8n'
  
  # Clean up temporary cookie file used in tests
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -f /tmp/n8n-cookies.txt 2>/dev/null || true'
    
  echo "n8n teardown complete"
  return 0
fi


# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "n8n Test (SQLite)"
echo "========================================"
echo ""

# Deploy the n8n configuration to test nodes
echo "Step 1: Deploying n8n configuration..."
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
echo "Step 3: Verifying n8n deployment..."
echo ""

# Wait for service and HTTP to be ready (n8n may take time to initialize)
for node in $TARGET; do
  wait_for_service "$node" "n8n" --timeout=60
  wait_for_port "$node" "5678" --timeout=30
  wait_for_http "$node" "http://localhost:5678/" "200 302 303" --timeout=60
done

# ============================================================================
# Check Service Status
# ============================================================================

echo ""
echo "Checking systemd services status..."
echo ""

for node in $TARGET; do
  echo "...checking services on $node"
  assert_service_active "$node" "n8n" || show_service_logs "$node" "n8n" 50
done

# ============================================================================
# Check Port Bindings
# ============================================================================

echo ""
echo "Step 4: Checking port bindings..."
echo ""

for node in $TARGET; do
  echo "Checking ports on $node..."
  assert_port_listening "$node" "5678" "n8n port 5678"
done

# ============================================================================
# Functional Tests
# ============================================================================

echo ""
echo "Step 5: Running functional tests..."
echo ""

for node in $TARGET; do
  echo "Testing n8n on $node..."
  
  # Test n8n HTTP response
  echo "  Testing n8n HTTP response..."
  assert_http_status "$node" "http://localhost:5678/" "200 302 303" "HTTP response"
  
  # Test n8n healthcheck endpoint
  echo "  Testing n8n healthcheck endpoint..."
  healthcheck=$(cmd_clean "$node" "curl -s http://localhost:5678/healthz 2>/dev/null")
  if [[ "$healthcheck" == *"ok"* ]] || [[ "$healthcheck" == *"healthy"* ]] || [[ -n "$healthcheck" ]]; then
    echo -e "  ${GREEN}✓${NC} n8n healthcheck responded: $healthcheck [pass]"
  else
    echo -e "  ${YELLOW}!${NC} n8n healthcheck response: $healthcheck [warn]"
  fi
  
  # ============================================================================
  # Authenticated REST API Tests (using session cookie)
  # ============================================================================
  echo "  Setting up authentication for API testing..."
  
  # Create authentication test script using base64 to avoid escaping issues
  AUTH_SCRIPT='#!/usr/bin/env bash

# Step 1: Create owner user (will fail if already exists, which is fine)
curl -s -X POST http://localhost:5678/rest/owner/setup \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"test@example.com\",\"firstName\":\"Test\",\"lastName\":\"User\",\"password\":\"TestPassword123!\"}" > /tmp/n8n-owner-result.json 2>&1

# Step 2: Login and get session cookie
curl -s -c /tmp/n8n-cookies.txt -X POST http://localhost:5678/rest/login \
  -H "Content-Type: application/json" \
  -d "{\"emailOrLdapLoginId\":\"test@example.com\",\"password\":\"TestPassword123!\"}" > /tmp/n8n-login-result.json 2>&1

# Check login result
if grep -q "test@example.com" /tmp/n8n-login-result.json 2>/dev/null; then
  echo "LOGIN_SUCCESS"
  
  # Step 3: Test REST API with session cookie (list workflows)
  WORKFLOWS_RESPONSE=$(curl -s -b /tmp/n8n-cookies.txt http://localhost:5678/rest/workflows 2>&1)
  
  if echo "$WORKFLOWS_RESPONSE" | jq -e ".data" > /dev/null 2>&1; then
    WORKFLOW_COUNT=$(echo "$WORKFLOWS_RESPONSE" | jq -r ".data | length")
    echo "REST_API_SUCCESS:workflows=$WORKFLOW_COUNT"
  else
    echo "REST_API_FAILED:$WORKFLOWS_RESPONSE"
  fi
  
  # Step 4: Test creating a workflow via REST API
  CREATE_WORKFLOW_RESPONSE=$(curl -s -b /tmp/n8n-cookies.txt -X POST http://localhost:5678/rest/workflows \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"Test Workflow\",\"nodes\":[],\"connections\":{},\"settings\":{},\"active\":false}" 2>&1)
  
  if echo "$CREATE_WORKFLOW_RESPONSE" | jq -e ".data.id" > /dev/null 2>&1; then
    WORKFLOW_ID=$(echo "$CREATE_WORKFLOW_RESPONSE" | jq -r ".data.id")
    echo "WORKFLOW_CREATED:$WORKFLOW_ID"
    
    # Step 5: Verify the workflow exists (skip delete - teardown will clean up)
    # Note: n8n archive and delete API uses internal endpoints that are not stable
    VERIFY_WORKFLOW_RESPONSE=$(curl -s -b /tmp/n8n-cookies.txt "http://localhost:5678/rest/workflows/$WORKFLOW_ID" 2>&1)
    if echo "$VERIFY_WORKFLOW_RESPONSE" | jq -e ".data.id" > /dev/null 2>&1; then
      echo "WORKFLOW_VERIFIED"
    else
      echo "WORKFLOW_VERIFY_FAILED:$VERIFY_WORKFLOW_RESPONSE"
    fi
  else
    echo "WORKFLOW_CREATE_FAILED:$CREATE_WORKFLOW_RESPONSE"
  fi
  
else
  echo "LOGIN_FAILED:$(cat /tmp/n8n-login-result.json)"
fi

# Cleanup
rm -f /tmp/n8n-owner-result.json /tmp/n8n-login-result.json /tmp/n8n-cookies.txt
'

  # Encode script and send to remote node
  AUTH_SCRIPT_B64=$(echo "$AUTH_SCRIPT" | base64 -w0)
  cmd "$node" "echo '$AUTH_SCRIPT_B64' | base64 -d > /tmp/n8n-auth-test.sh && chmod +x /tmp/n8n-auth-test.sh"
  
  # Run the auth test script
  auth_result=$(cmd_clean "$node" "bash /tmp/n8n-auth-test.sh")
  cmd "$node" "rm -f /tmp/n8n-auth-test.sh"
  
  # Parse results
  if [[ "$auth_result" == *"LOGIN_SUCCESS"* ]]; then
    echo -e "  ${GREEN}✓${NC} Login successful [pass]"
    
    # Check REST API access with session cookie
    if [[ "$auth_result" == *"REST_API_SUCCESS:"* ]]; then
      rest_info=$(echo "$auth_result" | grep "REST_API_SUCCESS:" | sed 's/.*REST_API_SUCCESS://')
      echo -e "  ${GREEN}✓${NC} REST API accessible ($rest_info) [pass]"
    elif [[ "$auth_result" == *"REST_API_FAILED:"* ]]; then
      rest_error=$(echo "$auth_result" | grep "REST_API_FAILED:" | sed 's/.*REST_API_FAILED://')
      echo -e "  ${RED}✗${NC} REST API failed: ${rest_error:0:100} [fail]"
    fi
    
    # Check workflow CRUD operations
    if [[ "$auth_result" == *"WORKFLOW_CREATED:"* ]]; then
      workflow_id=$(echo "$auth_result" | grep "WORKFLOW_CREATED:" | sed 's/.*WORKFLOW_CREATED://')
      echo -e "  ${GREEN}✓${NC} Workflow created (id: $workflow_id) [pass]"
      
      if [[ "$auth_result" == *"WORKFLOW_VERIFIED"* ]]; then
        echo -e "  ${GREEN}✓${NC} Workflow retrieved successfully [pass]"
      elif [[ "$auth_result" == *"WORKFLOW_VERIFY_FAILED:"* ]]; then
        verify_error=$(echo "$auth_result" | grep "WORKFLOW_VERIFY_FAILED:" | sed 's/.*WORKFLOW_VERIFY_FAILED://')
        echo -e "  ${RED}✗${NC} Workflow verify failed: ${verify_error:0:100} [fail]"
      fi
    elif [[ "$auth_result" == *"WORKFLOW_CREATE_FAILED:"* ]]; then
      create_error=$(echo "$auth_result" | grep "WORKFLOW_CREATE_FAILED:" | sed 's/.*WORKFLOW_CREATE_FAILED://')
      echo -e "  ${RED}✗${NC} Workflow create failed: ${create_error:0:100} [fail]"
    fi
    
  else
    login_error=$(echo "$auth_result" | grep "LOGIN_FAILED:" | sed 's/.*LOGIN_FAILED://')
    echo -e "  ${RED}✗${NC} Login failed: ${login_error:0:100} [fail]"
  fi

  # Check n8n data directory exists
  echo "  Testing n8n data directory..."
  assert_dir_exists "$node" "/var/lib/n8n" "n8n data directory"
  
  # Check SQLite database file exists
  echo "  Testing SQLite database file..."
  assert_file_exists "$node" "/var/lib/n8n/.n8n/database.sqlite" "SQLite database file"
  
  # Check service is not in error state
  echo "  Checking service state..."
  assert_service_running "$node" "n8n" "Service running normally"
  
  # Check for any failed units related to n8n
  echo "  Checking for failed units..."
  failed_units=$(cmd_clean "$node" "systemctl list-units --failed | grep -i n8n || echo 'none'")
  if [[ "$failed_units" == *"none"* ]] || [[ -z "$failed_units" ]] || [[ ! "$failed_units" == *"failed"* ]]; then
    echo -e "  ${GREEN}✓${NC} No failed n8n related units [pass]"
  else
    echo -e "  ${RED}✗${NC} Failed units found: $failed_units [fail]"
  fi
  
  # Check n8n process is running
  echo "  Checking n8n process..."
  assert_process_running "$node" "-f n8n" "n8n"
done

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "n8n Test Summary (SQLite)"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "n8n Test Complete"
echo "========================================"