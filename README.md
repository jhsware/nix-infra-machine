# nix-infra-machine

A standalone machine template for [nix-infra](https://github.com/jhsware/nix-infra). This template allows you to deploy and manage individual machines (or fleets of machines) with minimal configuration. All you need is a Hetzner Cloud account.

## Prerequisites

- [nix-infra CLI](https://github.com/jhsware/nix-infra/releases) installed
- A Hetzner Cloud account with an API token
- Git installed

Optional but recommended: Install [Nix](https://docs.determinate.systems/determinate-nix/) and work in a nix-shell for reproducible environments.

## Quick Start

1. Run this script to clone the template:

```sh
sh <(curl -L https://raw.githubusercontent.com/jhsware/nix-infra-machine/refs/heads/main/scripts/get-test.sh)
```

2. Get an API token from your Hetzner Cloud project

3. Edit the `.env` file in the created folder with your token and settings

4. Explore available commands:

```sh
cd test-nix-infra-machine

# Infrastructure management (create, destroy, ssh, etc.)
./cli --help

# Run test suite against machines
./__test__/run-tests.sh --help
```

## CLI Commands

The `cli` script is your main interface for managing infrastructure:

```sh
# Create a machine
./cli create node001

# Create multiple machines
./cli create node001 node002 node003

# SSH into a machine
./cli ssh node001

# Run commands on machines
./cli cmd --target=node001 "systemctl status nginx"

# Update configuration and deploy apps
./cli update node001

# Upgrade NixOS version
./cli upgrade node001

# Rollback to previous configuration
./cli rollback node001

# Run app module actions
./cli action --target=node001 myapp status

# Port forward from remote to local
./cli port-forward --target=node001 --port-mapping=8080:80

# Destroy machines
./cli destroy --target="node001 node002"

# Launch Claude with MCP integration
./cli claude
```

## Running Tests

The test workflow has two stages:

### 1. Create the test machines

The `create` command provisions the base machines and verifies basic functionality:

```sh
# Provision machines and run basic health checks
./__test__/run-tests.sh create
```

This creates and verifies: NixOS installation and basic system health.

### 2. Run app_module tests against the machines

Once you have running machines, use `run` to test specific app_modules:

```sh
# Run a single app test (e.g., mongodb)
./__test__/run-tests.sh run mongodb

# Keep test apps deployed after running
./__test__/run-tests.sh run --no-teardown mongodb
```

Available tests are defined in `__test__/<test-name>/test.sh`. List available tests:

```sh
ls __test__/*/test.sh
```

### Other test commands

```sh
# Reset machine state between test runs
./__test__/run-tests.sh reset mongodb

# Destroy all test machines
./__test__/run-tests.sh destroy

# Check machine health
./__test__/run-tests.sh test
```

Useful commands for exploring running test machines:

```sh
./__test__/run-tests.sh ssh node001
./__test__/run-tests.sh cmd --target=node001 "uptime"
```

### Developing App Modules with Claude
1. Install nix-infra, including nix-infra-dev-mcp

  https://github.com/jhsware/nix-infra

2. Run claude with access to nix-infra-dev-mcp:

```sh
./__test__/run-tests.sh claude-dev
```

3. Create a project and set instructions to:

```
Important! Only use tools from nix-infra Development Tools when reading or editing files.

You are an expert dev-ops engineer building nix-infra app modules for single machine deployment. You use Bash to write scripts and Nix to configure NixOS.

The project is in /Users/jhsware/DEV/TEST_INFRA_MACHINE you only edit files in /Users/jhsware/DEV/TEST_INFRA_MACHINE/app_modules and /Users/jhsware/DEV/TEST_INFRA_MACHINE/__test__

Example of an app module can be found at /Users/jhsware/DEV/TEST_INFRA_MACHINE/app_modules/mongodb with tests at /Users/jhsware/DEV/TEST_INFRA_MACHINE/__test__/mongodb
./app_modules/postgresql, ./__test__/postgresql
./app_modules/nextcloud, ./__test__/nextcloud
./app_modules/_unstable/crowdsec, ./__test__/crowdsec
./app_modules/_unstable/n8n, ./__test__/n9n

You are tasked with creating new app modules according to requirements by user. You will create and edit files in order to achieve this goal.

You will also create a test environment and run the app module test files in that environment. Do not destroy the test environment unless explicitly told to do so by the user.

You will perform actions in clear steps and ask the user for confirmation before each step is implemented. For more complex tasks, perform them in multiple sub steps to avoid sessions to time out or overflow.
```

4. Prompt Claude to create an app module and let it run tests using the run-test.sh cli

If a session stalls or fails to complete you can run the tests manually and paste the results. This can help in complex situations where Claude appears to get stuck or times out.

By having a compact project instruction and limited tool set you get maximum context space for your code and problem specific documentation. Claude will run tests and you are mainly required to coach it to complete the task. You may need to perform some limited manual editing and it is useful to create a new chat at times in order to allow Claude to clear it's context and avoid getting tunnel vision.

## Custom Configuration

To create your own configuration from scratch:

1. Clone this repository:

```sh
git clone git@github.com:jhsware/nix-infra-machine.git my-infrastructure
cd my-infrastructure
```

2. Set up environment:

```sh
cp .env.in .env
nano .env  # Add your HCLOUD_TOKEN and other settings
```

3. Create and manage your machines:

```sh
./cli create node001
./cli ssh node001
./cli update node001
```

## Directory Structure

```
.
├── cli                 # Main CLI for infrastructure management
├── .env                # Environment configuration (create from .env.in)
├── nodes/              # Per-node configuration files
├── node_types/         # Node type templates (standalone_machine.nix)
├── app_modules/        # Application module definitions
├── __test__/           # Test scripts and test definitions
└── scripts/            # Utility scripts
```

## Deploying Applications

Each node has its configuration in `nodes/`. Configure what apps to run and their settings here.

Deploy using the `update` command:

```sh
./cli update node001 node002
```

You can specify a custom node module:

```sh
./cli create --node-module=node_types/custom_machine.nix node001
```

## Secrets

Store secrets securely using the nix-infra CLI:

```sh
nix-infra secrets store -d . --secret="my-secret-value" --name="app.secret"
```

Or save action output as a secret:

```sh
./cli action --target=node001 myapp create-credentials --save-as-secret="myapp.credentials"
```

Secrets are encrypted locally and deployed as systemd credentials (automatically encrypted/decrypted on demand).

## Node Types

The default node type is `node_types/standalone_machine.nix`. Create custom node types in `node_types/` for different machine configurations, then reference them with `--node-module`.
