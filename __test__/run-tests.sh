#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
WORK_DIR=${WORK_DIR:-$(dirname "$SCRIPT_DIR")}
NIX_INFRA=${NIX_INFRA:-"nix-infra"}
NIXOS_VERSION=${NIXOS_VERSION:-"25.11"}
MACHINE_TYPE=${MACHINE_TYPE:-"cpx22"}
SSH_KEY="nixinfra-machine"
SSH_EMAIL=${SSH_EMAIL:-your-email@example.com}
ENV=${ENV:-.env}
SECRETS_PWD=${SECRETS_PWD:-my_secrets_password}
TARGET=${TARGET:-"testnode001"}

read -r -d '' __help_text__ <<EOF || true

nix-infra-machine Test Runner
=============================

Usage: $0 <command> [options]

Commands:
  create              Provision and initialize test machines
  run <test-name>     Run a specific test (e.g., mongodb)
  reset <test-name>   Reset test state without destroying machines
  destroy             Tear down all test machines
  status              Run basic health checks on machines
  update <nodes>      Update node configuration
  upgrade <nodes>     Upgrade NixOS version on nodes
  
  ssh <node>          SSH into a node
  cmd --target=<node> <command>    Run command on node(s)
  action --target=<node> <module> <cmd>   Run app action
  port-forward --target=<node> --port-mapping=<local:remote>

Options:
  --env=<file>        Environment file (default: .env)
  --no-teardown       Don't tear down after test
  --target=<nodes>    Target node(s) for commands
  --nixos-version=<version> Override version
  --machine-type=<type> Override machine type

Examples:
  # Run the full test cycle
  $0 create --env=.env
  $0 run mongodb --env=.env
  $0 destroy --env=.env

  # Run test without teardown for debugging
  $0 run mongodb --no-teardown --env=.env

  # Interactive debugging
  $0 ssh testnode001 --env=.env
  $0 cmd --target=testnode001 --env=.env "systemctl status podman-mongodb-4"

  # Reset and re-run a test
  $0 reset mongodb --env=.env
  $0 run mongodb --env=.env
EOF

if [[ "create upgrade run reset destroy update status ssh cmd action port-forward" == *"$1"* ]]; then
  CMD="$1"
  shift
else
  echo "$__help_text__"
  exit 1
fi

for i in "$@"; do
  case $i in
    --help)
    echo "$__help_text__"
    exit 0
    ;;
    --no-teardown)
    NO_TEARDOWN="true"
    shift
    ;;
    --env=*)
    ENV="${i#*=}"
    shift
    ;;
    --target=*)
    TARGET="${i#*=}"
    shift
    ;;
    --port-mapping=*)
    PORT_MAPPING="${i#*=}"
    shift
    ;;
    --nixos-version=*)
    NIXOS_VERSION="${i#*=}"
    shift
    ;;
    --machine-type=*)
    MACHINE_TYPE="${i#*=}"
    shift
    ;;
    *)
    REST="$@"
    ;;
  esac
done

if [ "$ENV" != "" ] && [ -f "$ENV" ]; then
  source $ENV
fi

# Check for nix-infra CLI if using default
if [ "$NIX_INFRA" = "nix-infra" ] && ! command -v nix-infra >/dev/null 2>&1; then
  echo "The 'nix-infra' CLI is required for this script to work."
  echo "Visit https://github.com/jhsware/nix-infra for installation instructions."
  exit 1
fi

if [ -z "$HCLOUD_TOKEN" ]; then
  echo "Missing env-var HCLOUD_TOKEN. Load through .env-file that is specified through --env."
  exit 1
fi

# Source shared helpers
source "$SCRIPT_DIR/shared.sh"
source "$SCRIPT_DIR/assertions.sh"
source "$SCRIPT_DIR/timeouts.sh"

# ============================================================================
# Test Runner Commands
# ============================================================================

if [ "$CMD" = "run" ]; then
  if [ ! -d "$WORK_DIR" ]; then
    echo "Working directory doesn't exist ($WORK_DIR)"
    exit 1
  fi

  if [ "$REST" == "" ]; then
    echo "Missing test name. Available tests:"
    ls -d "$WORK_DIR/__test__"/*/ 2>/dev/null | xargs -n1 basename | grep -v "^$"
    exit 1
  fi

  last_test="${REST##* }"
  for _test_name in $REST; do
    if [ ! -d "$WORK_DIR/__test__/$_test_name" ]; then
      echo "Test directory doesn't exist (__test__/$_test_name)"
    else
      echo "========================================"
      echo "Running test: $_test_name"
      echo "========================================"
      TEST_DIR="__test__/$_test_name" source "$WORK_DIR/__test__/$_test_name/test.sh"

      if [ "$_test_name" != "$last_test" ] || [ "$NO_TEARDOWN" != "true" ]; then
        echo "Cleaning up after test: $_test_name"
        TEST_DIR="__test__/$_test_name" CMD="teardown" source "$WORK_DIR/__test__/$_test_name/test.sh"
      fi
    fi
  done

  if [ "$NO_TEARDOWN" != "true" ]; then
    echo "Resetting node configurations..."
    $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" 'rm -f /etc/nixos/$(hostname).nix'
    $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" "nixos-rebuild switch --fast"

  fi
  
  exit 0
fi

if [ "$CMD" = "reset" ]; then
  if [ ! -d "$WORK_DIR" ]; then
    echo "Working directory doesn't exist ($WORK_DIR)"
    exit 1
  fi

  if [ "$REST" == "" ]; then
    echo "Missing test name"
    exit 1
  fi

  echo "Cleaning up node configuration..."
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" 'rm -f /etc/nixos/$(hostname).nix'
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" "nixos-rebuild switch --fast"


  sleep 1

  echo "Running test teardown..."
  for _test_name in $REST; do
    if [ ! -d "$WORK_DIR/__test__/$_test_name" ]; then
      echo "Test directory doesn't exist (__test__/$_test_name)"
    else
      TEST_DIR="__test__/$_test_name" CMD="teardown" source "$WORK_DIR/__test__/$_test_name/test.sh"
    fi
  done

  echo "Removing secrets..."
  rm -f "$WORK_DIR/secrets/"*

  echo "...reset complete!"
  exit 0
fi

# ============================================================================
# Fleet Management Commands
# ============================================================================

destroyFleet() {
  $NIX_INFRA fleet destroy -d "$WORK_DIR" --batch \
      --target="$TARGET"

  $NIX_INFRA ssh-key remove -d "$WORK_DIR" --batch --name="$SSH_KEY"

  echo "Remove /secrets..."
  rm -rf "$WORK_DIR/secrets"
}


cleanupOnFail() {
  if [ $1 -ne 0 ]; then
    echo "$2"
    destroyFleet
    exit 1
  fi
}

if [ "$CMD" = "destroy" ]; then
  destroyFleet
  exit 0
fi

if [ "$CMD" = "status" ]; then
  testFleet "$TARGET"
  exit 0
fi


if [ "$CMD" = "update" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 update --env=$ENV [node1 node2 ...]"
    exit 1
  fi
  $NIX_INFRA fleet update -d "$WORK_DIR" --batch --env="$ENV" \
    --nixos-version="$NIXOS_VERSION" \
    --node-module="node_types/standalone_machine.nix" \
    --target="$REST" \
    --rebuild
  
  $NIX_INFRA fleet deploy-apps -d "$WORK_DIR" --batch --env="$ENV" \
    --target="$REST"
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$REST" "nixos-rebuild switch --fast"
  exit 0
fi

if [ "$CMD" = "upgrade" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 upgrade --env=$ENV [node1 node2 ...]"
    exit 1
  fi
  $NIX_INFRA fleet upgrade-nixos -d "$WORK_DIR" --batch --env="$ENV" --nixos-version="$NIXOS_VERSION" \
    --target="$REST"
  exit 0
fi


# ============================================================================
# Interactive Commands
# ============================================================================

if [ "$CMD" = "ssh" ]; then
  if [ -z "$REST" ]; then
    echo "Usage: $0 ssh --env=$ENV [node]"
    exit 1
  fi
  $NIX_INFRA fleet ssh -d "$WORK_DIR" --env="$ENV" --target="$REST"
  exit 0
fi

if [ "$CMD" = "cmd" ]; then
  if [ -z "$TARGET" ] || [ -z "$REST" ]; then
    echo "Usage: $0 cmd --env=$ENV --target=[node] [cmd goes here]"
    exit 1
  fi
  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" "$REST"
  exit 0
fi

if [ "$CMD" = "action" ]; then
  if [ -z "$TARGET" ] || [ -z "$REST" ]; then
    echo "Usage: $0 action --env=$ENV --target=[node] [module] [cmd]"
    exit 1
  fi
  
  read -r module cmd <<< "$REST"
  $NIX_INFRA fleet action -d "$WORK_DIR" --target="$TARGET" --app-module="$module" \
    --cmd="$cmd"
  exit 0
fi

if [ "$CMD" = "port-forward" ]; then
  if [ -z "$TARGET" ] || [ -z "$PORT_MAPPING" ]; then
    echo "Usage: $0 port-forward --env=$ENV --target=[node] --port-mapping=[local:remote]"
    exit 1
  fi

  OLD_IFS=$IFS
  IFS=: read LOCAL_PORT REMOTE_PORT <<< "$PORT_MAPPING"
  IFS=$OLD_IFS

  $NIX_INFRA fleet port-forward -d "$WORK_DIR" --env="$ENV" \
    --target="$TARGET" \
    --local-port="$LOCAL_PORT" \
    --remote-port="$REMOTE_PORT"
  exit 0
fi

# ============================================================================
# Create Command - Provision and Initialize Test Fleet
# ============================================================================

if [ "$CMD" = "create" ]; then
  if [ -d "$WORK_DIR/secrets" ]; then
    echo "Found existing ./secrets, this appears to be a live project. Creating a test environment may destroy it."
    exit 1
  fi

  if [ ! -f "$ENV" ]; then
    read -r -d '' env <<EOF || true
# NOTE: The following secrets are required for various operations
# by the nix-infra CLI. Make sure they are encrypted when not in use
SSH_KEY=$SSH_KEY
SSH_EMAIL=$SSH_EMAIL

# The following token is needed to perform provisioning and discovery
HCLOUD_TOKEN=$HCLOUD_TOKEN

# Password for the secrets that are stored in this repo
# These need to be kept secret.
SECRETS_PWD=$SECRETS_PWD
EOF
    echo "$env" > "$WORK_DIR/.env"
  fi

  _start=$(date +%s)

  $NIX_INFRA init -d "$WORK_DIR" --no-cert-auth --batch
  ssh-add "$WORK_DIR/ssh/$SSH_KEY"
  
  echo "*** Provisioning NixOS $NIXOS_VERSION ***"
  $NIX_INFRA fleet provision -d "$WORK_DIR" --batch --env="$ENV" \
      --nixos-version="$NIXOS_VERSION" \
      --ssh-key=$SSH_KEY \
      --location=hel1 \
      --machine-type="$MACHINE_TYPE" \
      --node-names="$TARGET"

  cleanupOnFail $? "WARNING: Provisioning failed! Cleaning up..."

  _provision=$(date +%s)

  $NIX_INFRA fleet init-machine -d "$WORK_DIR" --batch --env="$ENV" \
      --nixos-version="$NIXOS_VERSION" \
      --target="$TARGET" \
      --node-module="node_types/standalone_machine.nix"

  $NIX_INFRA fleet cmd -d "$WORK_DIR" --target="$TARGET" "nixos-rebuild switch --fast"

  _init_nodes=$(date +%s)

  # Verify the operation of the test fleet
  echo "******************************************"
  testFleet "$TARGET"
  echo "******************************************"


  _end=$(date +%s)

  echo "            **              **            "
  echo "            **              **            "
  echo "******************************************"

  printTime() {
    local _start=$1; local _end=$2; local _secs=$((_end-_start))
    printf '%02dh:%02dm:%02ds' $((_secs/3600)) $((_secs%3600/60)) $((_secs%60))
  }
  printf '+ provision  %s\n' "$(printTime $_start $_provision)"
  printf '+ init       %s\n' "$(printTime $_provision $_init_nodes)"
  printf '+ test       %s\n' "$(printTime $_init_nodes $_end)"
  printf '= SUM %s\n' "$(printTime $_start $_end)"
  echo "***************** DONE *******************"
fi
