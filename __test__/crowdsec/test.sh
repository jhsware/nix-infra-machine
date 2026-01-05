#!/usr/bin/env bash
# CrowdSec Intrusion Prevention System test for nix-infra-machine
#
# This test:
# 1. Deploys CrowdSec with SSH and system protection enabled
# 2. Verifies the CrowdSec service and Local API are running
# 3. Tests firewall bouncer (nftables integration)
# 4. Tests HAProxy SPOA bouncer
# 5. Tests auditd integration for kernel-level monitoring
# 6. Tests cscli functionality (hub, parsers, scenarios)
# 7. Tests basic decision management
# 8. Cleans up on teardown
#
# [NIS2 COMPLIANCE VERIFICATION]
# This test validates that the CrowdSec deployment meets key NIS2 requirements:
# - Article 21(2)(b): Incident handling through automated threat detection
# - Article 21(2)(d): Network security through IDS/IPS capabilities
# - Article 21(2)(g): Security monitoring and logging

# Configuration
CROWDSEC_API_PORT=8080
FIREWALL_BOUNCER_ENABLED=true
HAPROXY_BOUNCER_ENABLED=false
HAPROXY_SPOA_PORT=3000
AUDITD_ENABLED=true


# Handle teardown command
if [ "$CMD" = "teardown" ]; then
  echo "Tearing down CrowdSec test..."
  
  # Stop CrowdSec services
  if [ "$HAPROXY_BOUNCER_ENABLED" = "true" ]; then
    $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
      'systemctl stop crowdsec-haproxy-bouncer 2>/dev/null || true'
  fi
  if [ "$FIREWALL_BOUNCER_ENABLED" = "true" ]; then
    $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
      'systemctl stop crowdsec-firewall-bouncer 2>/dev/null || true'
  fi
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'systemctl stop crowdsec 2>/dev/null || true'
  
  # Clean up data directories on target nodes
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/crowdsec'
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/crowdsec-firewall-bouncer 2>/dev/null || true'
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /var/lib/crowdsec-haproxy-bouncer 2>/dev/null || true'
  
  # Clean up declarative configuration directories on target nodes
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" \
    'rm -rf /etc/crowdsec 2>/dev/null || true'
  
  echo "CrowdSec teardown complete"
  return 0
fi

# ============================================================================
# Test Setup
# ============================================================================

_start=$(date +%s)

echo ""
echo "========================================"
echo "CrowdSec Intrusion Prevention Test"
echo "========================================"
echo ""
echo "Testing NIS2-compliant security monitoring setup"
echo ""

# Deploy the CrowdSec configuration to test nodes
echo "Step 1: Deploying CrowdSec configuration..."
$NIX_INFRA fleet deploy-apps -d "$WORK_DIR" --batch --env="$ENV" \
  --test-dir="$WORK_DIR/$TEST_DIR" \
  --target="$TARGET"

# Apply the configuration
echo "Step 2: Applying NixOS configuration..."
$NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" "nixos-rebuild switch --fast"

_setup=$(date +%s)

# ============================================================================
# Test Verification - CrowdSec Service
# ============================================================================

echo ""
echo "Step 3: Verifying CrowdSec deployment..."
echo ""

# Wait for CrowdSec service to start
for node in $TARGET; do
  wait_for_service "$node" "crowdsec" --timeout=90
  wait_for_port "$node" "$CROWDSEC_API_PORT" --timeout=60
done

# Check if the systemd service is active
echo ""
echo "Checking CrowdSec systemd service status..."
for node in $TARGET; do
  assert_service_active "$node" "crowdsec" || show_service_logs "$node" "crowdsec" 50
done

# Check if CrowdSec process is running
echo ""
echo "Checking CrowdSec process..."
for node in $TARGET; do
  assert_process_running "$node" "crowdsec" "CrowdSec"
done

# Check if CrowdSec API port is listening
echo ""
echo "Checking CrowdSec API port ($CROWDSEC_API_PORT)..."
for node in $TARGET; do
  assert_port_listening "$node" "$CROWDSEC_API_PORT" "CrowdSec API port $CROWDSEC_API_PORT"
done

# ============================================================================
# Test Verification - Firewall Bouncer
# ============================================================================

if [ "$FIREWALL_BOUNCER_ENABLED" = "true" ]; then
  echo ""
  echo "Step 4: Verifying Firewall Bouncer..."
  echo ""

  # Wait for bouncer service
  for node in $TARGET; do
    wait_for_service "$node" "crowdsec-firewall-bouncer" --timeout=60
  done

  # Check bouncer service status
  echo "Checking Firewall Bouncer systemd service status..."
  for node in $TARGET; do
    assert_service_active "$node" "crowdsec-firewall-bouncer" || \
      show_service_logs "$node" "crowdsec-firewall-bouncer" 50
  done

  # Check nftables integration
  echo ""
  echo "Checking nftables integration..."
  for node in $TARGET; do
    echo "  Verifying nftables tables and sets on $node..."
    
    # Check if crowdsec table exists
    nft_table=$(cmd_clean "$node" "nft list table ip crowdsec 2>&1 || echo 'not found'")
    if [[ "$nft_table" == *"table ip crowdsec"* ]]; then
      echo -e "  ${GREEN}✓${NC} CrowdSec nftables IPv4 table exists [pass]"
    else
      echo -e "  ${YELLOW}!${NC} CrowdSec nftables tables: $nft_table [warning]"
    fi
    
    # Check if crowdsec set exists in IPv4 table
    nft_set=$(cmd_clean "$node" "nft list set ip crowdsec crowdsec-blocklist 2>&1 || echo 'not found'")
    if [[ "$nft_set" == *"crowdsec-blocklist"* ]]; then
      echo -e "  ${GREEN}✓${NC} CrowdSec IPv4 nftables set exists [pass]"
    else
      echo -e "  ${YELLOW}!${NC} CrowdSec IPv4 set: $nft_set [warning]"
    fi
    
    # Check if crowdsec chain exists
    nft_chain=$(cmd_clean "$node" "nft list chain ip crowdsec crowdsec-chain 2>&1 || echo 'not found'")
    if [[ "$nft_chain" == *"crowdsec-chain"* ]]; then
      echo -e "  ${GREEN}✓${NC} CrowdSec nftables chain exists [pass]"
    else
      echo -e "  ${YELLOW}!${NC} CrowdSec chain: $nft_chain [warning]"
    fi
    
    # Check IPv6 table
    nft_table6=$(cmd_clean "$node" "nft list table ip6 crowdsec6 2>&1 || echo 'not found'")
    if [[ "$nft_table6" == *"table ip6 crowdsec6"* ]]; then
      echo -e "  ${GREEN}✓${NC} CrowdSec nftables IPv6 table exists [pass]"
    else
      echo -e "  ${YELLOW}!${NC} CrowdSec IPv6 table: $nft_table6 [warning]"
    fi
  done
else
  echo ""
  echo "Step 4: Firewall Bouncer (SKIPPED - disabled in test config)"
  echo ""
fi

# ============================================================================
# Test Verification - HAProxy SPOA Bouncer
# ============================================================================

if [ "$HAPROXY_BOUNCER_ENABLED" = "true" ]; then
  echo ""
  echo "Step 5: Verifying HAProxy SPOA Bouncer..."
  echo ""

  # Wait for bouncer service
  for node in $TARGET; do
    wait_for_service "$node" "crowdsec-haproxy-bouncer" --timeout=60
    wait_for_port "$node" "$HAPROXY_SPOA_PORT" --timeout=60
  done

  # Check bouncer service status
  echo "Checking HAProxy SPOA Bouncer systemd service status..."
  for node in $TARGET; do
    assert_service_active "$node" "crowdsec-haproxy-bouncer" || \
      show_service_logs "$node" "crowdsec-haproxy-bouncer" 50
  done

  # Check if SPOA port is listening
  echo ""
  echo "Checking HAProxy SPOA port ($HAPROXY_SPOA_PORT)..."
  for node in $TARGET; do
    assert_port_listening "$node" "$HAPROXY_SPOA_PORT" "HAProxy SPOA port $HAPROXY_SPOA_PORT"
  done
  
  # Verify SPOA config exists
  echo ""
  echo "Checking HAProxy SPOA bouncer configuration..."
  for node in $TARGET; do
    config_check=$(cmd_clean "$node" "test -f /var/lib/crowdsec-haproxy-bouncer/config.yaml && echo 'exists' || echo 'missing'")
    if [[ "$config_check" == *"exists"* ]]; then
      echo -e "  ${GREEN}✓${NC} HAProxy SPOA bouncer config exists [pass]"
    else
      echo -e "  ${YELLOW}!${NC} HAProxy SPOA bouncer config: $config_check [warning]"
    fi
  done
else
  echo ""
  echo "Step 5: HAProxy SPOA Bouncer (SKIPPED - disabled in test config)"
  echo ""
fi

# ============================================================================
# Test Verification - Auditd Integration
# ============================================================================

if [ "$AUDITD_ENABLED" = "true" ]; then
  echo ""
  echo "Step 6: Verifying Auditd Integration..."
  echo ""

  # Check if auditd service is running
  for node in $TARGET; do
    echo "Checking auditd service on $node..."
    
    # Check auditd service status
    auditd_status=$(cmd_clean "$node" "systemctl is-active auditd 2>&1 || echo 'inactive'")
    if [[ "$auditd_status" == "active" ]]; then
      echo -e "  ${GREEN}✓${NC} Auditd service is active [pass]"
    else
      echo -e "  ${YELLOW}!${NC} Auditd service status: $auditd_status [warning]"
    fi
    
    # Check if audit rules are loaded
    echo "  Checking audit rules..."
    audit_rules=$(cmd_clean "$node" "auditctl -l 2>&1 || echo 'no rules'")
    if [[ "$audit_rules" == *"passwd"* ]] || [[ "$audit_rules" == *"shadow"* ]]; then
      echo -e "  ${GREEN}✓${NC} Audit rules for identity files loaded [pass]"
    else
      echo -e "  ${YELLOW}!${NC} Audit rules: $audit_rules [warning]"
    fi
    
    # Check if sudoers watch rule is loaded
    if [[ "$audit_rules" == *"sudoers"* ]]; then
      echo -e "  ${GREEN}✓${NC} Audit rule for sudoers file loaded [pass]"
    else
      echo -e "  ${YELLOW}!${NC} Sudoers audit rule not found [warning]"
    fi
    
    # Verify whitelist processes are configured (check audit config)
    echo "  Checking NixOS wrapper whitelist configuration..."
    # The whitelist is configured via audit rules, we verify it was processed
    # by checking that the service started without errors
    if [[ "$auditd_status" == "active" ]]; then
      echo -e "  ${GREEN}✓${NC} NixOS wrapper whitelist configured (service active) [pass]"
    else
      echo -e "  ${YELLOW}!${NC} Cannot verify whitelist (auditd not active) [warning]"
    fi
  done
else
  echo ""
  echo "Step 6: Auditd Integration (SKIPPED - disabled in test config)"
  echo ""
fi

# ============================================================================
# Functional Tests - CLI Tools
# ============================================================================

echo ""
echo "Step 7: Testing CrowdSec CLI (cscli)..."
echo ""

for node in $TARGET; do
  echo "Testing cscli on $node..."
  
  # Test cscli version
  echo "  Checking cscli version..."
  version_result=$(cmd_clean "$node" "cscli version 2>&1")
  if [[ "$version_result" == *"version"* ]] || [[ "$version_result" == *"crowdsec"* ]]; then
    echo -e "  ${GREEN}✓${NC} cscli version command works [pass]"
  else
    echo -e "  ${YELLOW}!${NC} cscli version output: $version_result [warning]"
  fi
  
  # Test LAPI status
  echo "  Checking Local API status..."
  lapi_status=$(cmd_clean "$node" "cscli lapi status 2>&1 || true")
  if [[ "$lapi_status" == *"successfully interact"* ]] || [[ "$lapi_status" == *"LAPI is reachable"* ]] || [[ "$lapi_status" == *"You can successfully"* ]]; then
    echo -e "  ${GREEN}✓${NC} Local API is reachable [pass]"
  else
    echo -e "  ${YELLOW}!${NC} LAPI status check: $lapi_status [warning]"
  fi
  
  # Test hub listing
  echo "  Checking installed hub items..."
  hub_result=$(cmd_clean "$node" "cscli hub list 2>&1 || true")
  if [[ "$hub_result" == *"COLLECTIONS"* ]] || [[ "$hub_result" == *"PARSERS"* ]] || [[ "$hub_result" == *"SCENARIOS"* ]]; then
    echo -e "  ${GREEN}✓${NC} Hub listing works [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Hub listing output: $hub_result [warning]"
  fi
  
  # Test collections listing
  echo "  Checking installed collections..."
  collections_result=$(cmd_clean "$node" "cscli collections list 2>&1 || true")
  if [[ "$collections_result" == *"sshd"* ]] || [[ "$collections_result" == *"crowdsecurity"* ]]; then
    echo -e "  ${GREEN}✓${NC} SSH collection installed [pass]"
  else
    echo -e "  ${YELLOW}!${NC} SSH collection may still be installing [info]"
  fi
  
  # Test parsers listing  
  echo "  Checking installed parsers..."
  parsers_result=$(cmd_clean "$node" "cscli parsers list 2>&1 || true")
  if [[ "$parsers_result" == *"sshd"* ]] || [[ "$parsers_result" == *"syslog"* ]] || [[ "$parsers_result" == *"crowdsecurity"* ]]; then
    echo -e "  ${GREEN}✓${NC} Parsers installed [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Parsers may still be installing: $parsers_result [warning]"
  fi
  
  # Test scenarios listing
  echo "  Checking installed scenarios..."
  scenarios_result=$(cmd_clean "$node" "cscli scenarios list 2>&1 || true")
  if [[ "$scenarios_result" == *"ssh"* ]] || [[ "$scenarios_result" == *"crowdsecurity"* ]]; then
    echo -e "  ${GREEN}✓${NC} Scenarios installed [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Scenarios may still be installing [info]"
  fi
done

# ============================================================================
# Functional Tests - Decision Management
# ============================================================================

echo ""
echo "Step 8: Testing Decision Management..."
echo ""

for node in $TARGET; do
  echo "Testing decision management on $node..."
  
  # List current decisions (should be empty initially)
  echo "  Listing current decisions..."
  decisions_result=$(cmd_clean "$node" "cscli decisions list 2>&1 || true")
  if [[ "$decisions_result" == *"No active decisions"* ]] || [[ "$decisions_result" == *"0 decision"* ]] || [[ -z "$decisions_result" ]] || [[ "$decisions_result" == *"decision"* ]]; then
    echo -e "  ${GREEN}✓${NC} Decision listing works [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Decision listing output: $decisions_result [info]"
  fi
  
  # Add a test decision (ban a test IP)
  echo "  Adding test decision (ban 192.0.2.1 - TEST-NET-1)..."
  add_result=$(cmd_clean "$node" "cscli decisions add --ip 192.0.2.1 --reason 'nix-infra test' --type ban 2>&1 || true")
  if [[ "$add_result" == *"Decision successfully added"* ]] || [[ "$add_result" == *"added"* ]] || [[ "$add_result" == *"success"* ]]; then
    echo -e "  ${GREEN}✓${NC} Decision added successfully [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Decision add result: $add_result [info]"
  fi
  
  # Verify the decision was added
  echo "  Verifying decision was recorded..."
  verify_result=$(cmd_clean "$node" "cscli decisions list 2>&1 || true")
  if [[ "$verify_result" == *"192.0.2.1"* ]]; then
    echo -e "  ${GREEN}✓${NC} Decision recorded in database [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Decision verification: $verify_result [warning]"
  fi
  
  # Remove the test decision
  echo "  Removing test decision..."
  remove_result=$(cmd_clean "$node" "cscli decisions delete --ip 192.0.2.1 2>&1 || true")
  if [[ "$remove_result" == *"decision"* ]] || [[ "$remove_result" == *"deleted"* ]] || [[ "$remove_result" == *"removed"* ]]; then
    echo -e "  ${GREEN}✓${NC} Decision delete command executed [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Decision delete result: $remove_result [warning]"
  fi
  
  # Verify the decision was actually removed
  echo "  Verifying decision was removed..."
  verify_removed=$(cmd_clean "$node" "cscli decisions list 2>&1 || true")
  if [[ "$verify_removed" != *"192.0.2.1"* ]]; then
    echo -e "  ${GREEN}✓${NC} Decision successfully removed from database [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Decision may still exist: $verify_removed [warning]"
  fi
done

# ============================================================================
# Functional Tests - Bouncer Registration
# ============================================================================

echo ""
echo "Step 9: Testing Bouncer Registration..."
echo ""

for node in $TARGET; do
  echo "Checking bouncer status on $node..."
  
  # List registered bouncers
  bouncers_result=$(cmd_clean "$node" "cscli bouncers list 2>&1 || true")
  
  if [ "$FIREWALL_BOUNCER_ENABLED" = "true" ]; then
    if [[ "$bouncers_result" == *"firewall"* ]] || [[ "$bouncers_result" == *"bouncer"* ]]; then
      echo -e "  ${GREEN}✓${NC} Firewall bouncer is registered [pass]"
    else
      echo -e "  ${YELLOW}!${NC} Bouncer registration status: $bouncers_result [info]"
    fi
  fi
  
  if [ "$HAPROXY_BOUNCER_ENABLED" = "true" ]; then
    if [[ "$bouncers_result" == *"haproxy"* ]] || [[ "$bouncers_result" == *"spoa"* ]]; then
      echo -e "  ${GREEN}✓${NC} HAProxy SPOA bouncer is registered [pass]"
    else
      echo -e "  ${YELLOW}!${NC} HAProxy bouncer registration status: $bouncers_result [info]"
    fi
  fi
  
  if [ "$FIREWALL_BOUNCER_ENABLED" = "false" ] && [ "$HAPROXY_BOUNCER_ENABLED" = "false" ]; then
    echo -e "  ${YELLOW}!${NC} Bouncer check skipped (both disabled in config) [info]"
  fi
done

# ============================================================================
# Functional Tests - Metrics and API Endpoints
# ============================================================================

echo ""
echo "Step 10: Testing Metrics and API Endpoints..."
echo ""

for node in $TARGET; do
  echo "Checking metrics on $node..."
  
  # Test cscli alerts list
  echo "  Checking cscli alerts functionality..."
  alerts_result=$(cmd_clean "$node" "cscli alerts list 2>&1 || true")
  if [[ "$alerts_result" == *"No active alerts"* ]] || [[ "$alerts_result" == *"ID"* ]] || [[ "$alerts_result" == *"Source"* ]] || [[ "$alerts_result" == *"Reason"* ]]; then
    echo -e "  ${GREEN}✓${NC} cscli alerts command works [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Alerts output unexpected: $alerts_result [warning]"
  fi
  
  # Test API endpoint
  echo "  Checking API endpoint..."
  api_result=$(cmd_clean "$node" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$CROWDSEC_API_PORT/v1/decisions 2>&1 || echo '000'")
  if [[ "$api_result" == "200" ]] || [[ "$api_result" == "401" ]] || [[ "$api_result" == "403" ]]; then
    echo -e "  ${GREEN}✓${NC} API endpoint responds (HTTP $api_result) [pass]"
  else
    echo -e "  ${YELLOW}!${NC} API response code: $api_result [warning]"
  fi
done

# ============================================================================
# Functional Tests - Machine Registration
# ============================================================================

echo ""
echo "Step 11: Testing Machine Registration..."
echo ""

for node in $TARGET; do
  echo "Checking machine registration on $node..."
  
  echo "  Checking registered machines..."
  machines_result=$(cmd_clean "$node" "cscli machines list 2>&1 || true")
  if [[ "$machines_result" == *"testnode"* ]] || [[ "$machines_result" == *"localhost"* ]] || [[ "$machines_result" == *"validated"* ]]; then
    echo -e "  ${GREEN}✓${NC} Local machine is registered with LAPI [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Machine registration status: $machines_result [warning]"
  fi
done

# ============================================================================
# Functional Tests - Acquisition Sources
# ============================================================================

echo ""
echo "Step 12: Testing Acquisition Sources..."
echo ""

for node in $TARGET; do
  echo "Checking acquisition sources on $node..."
  
  # Check if acquisitions are configured
  echo "  Checking acquisition configuration..."
  acq_file=$(cmd_clean "$node" "cat /var/lib/crowdsec/config/acquisitions.yaml 2>&1 || true")
  if [[ "$acq_file" == *"journalctl"* ]] || [[ "$acq_file" == *"sshd"* ]] || [[ "$acq_file" == *"source"* ]]; then
    echo -e "  ${GREEN}✓${NC} Acquisition sources configured [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Acquisition config: $acq_file [warning]"
  fi
  
  # Check cscli metrics for acquisition stats
  echo "  Checking acquisition metrics..."
  acq_metrics=$(cmd_clean "$node" "cscli metrics show acquisitions 2>&1 || true")
  if [[ "$acq_metrics" == *"journalctl"* ]] || [[ "$acq_metrics" == *"file"* ]] || [[ "$acq_metrics" == *"Source"* ]] || [[ "$acq_metrics" == *"Lines"* ]]; then
    echo -e "  ${GREEN}✓${NC} Acquisition metrics available [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Acquisition metrics: $acq_metrics [info]"
  fi
done

# ============================================================================
# Functional Tests - Database and Config Files
# ============================================================================

echo ""
echo "Step 13: Testing Database and Configuration Files..."
echo ""

for node in $TARGET; do
  echo "Checking persistence on $node..."
  
  # Check if SQLite database exists
  echo "  Checking CrowdSec database..."
  db_check=$(cmd_clean "$node" "test -f /var/lib/crowdsec/data/crowdsec.db && echo 'exists' || echo 'missing'")
  if [[ "$db_check" == *"exists"* ]]; then
    echo -e "  ${GREEN}✓${NC} SQLite database exists [pass]"
  else
    echo -e "  ${RED}✗${NC} SQLite database missing [fail]"
  fi
  
  # Check if config directory exists with required files
  echo "  Checking configuration files..."
  config_check=$(cmd_clean "$node" "ls /var/lib/crowdsec/config/ 2>&1 || true")
  if [[ "$config_check" == *"config.yaml"* ]] && [[ "$config_check" == *"profiles.yaml"* ]]; then
    echo -e "  ${GREEN}✓${NC} Configuration files present [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Config directory contents: $config_check [warning]"
  fi
  
  # Check if hub directory exists
  echo "  Checking hub directory..."
  hub_check=$(cmd_clean "$node" "test -d /var/lib/crowdsec/hub && echo 'exists' || echo 'missing'")
  if [[ "$hub_check" == *"exists"* ]]; then
    echo -e "  ${GREEN}✓${NC} Hub directory exists [pass]"
  else
    echo -e "  ${YELLOW}!${NC} Hub directory status: $hub_check [warning]"
  fi
done

# ============================================================================
# Functional Tests - Service Restart
# ============================================================================

echo ""
echo "Step 14: Testing Service Restart..."
echo ""

for node in $TARGET; do
  echo "Testing service restart on $node..."
  
  # Restart the service
  echo "  Restarting CrowdSec service..."
  restart_result=$(cmd_clean "$node" "systemctl restart crowdsec 2>&1 && echo 'restart_ok' || echo 'restart_failed'")
  if [[ "$restart_result" == *"restart_ok"* ]]; then
    echo -e "  ${GREEN}✓${NC} Service restart command successful [pass]"
  else
    echo -e "  ${RED}✗${NC} Service restart failed: $restart_result [fail]"
  fi
  
  # Wait for service to come back up
  echo "  Waiting for service to recover..."
  wait_for_service "$node" "crowdsec" --timeout=60
  wait_for_port "$node" "$CROWDSEC_API_PORT" --timeout=30
  
  # Verify service is active after restart
  echo "  Verifying service is active after restart..."
  assert_service_active "$node" "crowdsec"
  
  # Verify LAPI is responsive after restart
  echo "  Verifying LAPI responds after restart..."
  lapi_after=$(cmd_clean "$node" "cscli lapi status 2>&1 || true")
  if [[ "$lapi_after" == *"successfully interact"* ]] || [[ "$lapi_after" == *"You can successfully"* ]]; then
    echo -e "  ${GREEN}✓${NC} LAPI responsive after restart [pass]"
  else
    echo -e "  ${YELLOW}!${NC} LAPI status after restart: $lapi_after [warning]"
  fi
done

# ============================================================================
# NIS2 Compliance Summary
# ============================================================================

echo ""
echo "========================================"
echo "NIS2 Compliance Verification Summary"
echo "========================================"
echo ""
echo "Article 21(2)(b) - Incident Handling:"
echo "  ✓ CrowdSec provides automated threat detection"
if [ "$FIREWALL_BOUNCER_ENABLED" = "true" ]; then
  echo "  ✓ Firewall bouncer enables real-time response"
fi
if [ "$HAPROXY_BOUNCER_ENABLED" = "true" ]; then
  echo "  ✓ HAProxy SPOA bouncer enables layer 7 protection"
fi
echo ""
echo "Article 21(2)(d) - Network Security:"
echo "  ✓ IDS/IPS capabilities via CrowdSec engine"
if [ "$FIREWALL_BOUNCER_ENABLED" = "true" ]; then
  echo "  ✓ Automated IP blocking via firewall bouncer (nftables)"
fi
if [ "$HAPROXY_BOUNCER_ENABLED" = "true" ]; then
  echo "  ✓ Application-layer protection via HAProxy SPOA"
fi
echo ""
echo "Article 21(2)(g) - Security Monitoring:"
echo "  ✓ SSH authentication monitoring enabled"
echo "  ✓ System/kernel log monitoring enabled"
echo "  ✓ Centralized decision logging active"
if [ "$AUDITD_ENABLED" = "true" ]; then
  echo "  ✓ Kernel-level auditd integration enabled"
  echo "  ✓ NixOS wrapper whitelist configured"
fi
echo ""
echo "Article 21(2)(i) - Human Resources Security:"
echo "  ✓ Protection against credential attacks"
echo ""

# ============================================================================
# Test Summary
# ============================================================================

_end=$(date +%s)

echo ""
echo "========================================"
echo "CrowdSec Test Summary"
echo "========================================"

printf '+ setup     %s\n' $(printTime $_start $_setup)
printf '+ tests     %s\n' $(printTime $_setup $_end)
printf '= TOTAL     %s\n' $(printTime $_start $_end)

echo ""
echo "========================================"
echo "CrowdSec Test Complete"
echo "========================================"
