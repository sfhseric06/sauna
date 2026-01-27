# Tests

Test suite for validating Shelly scripts and deployed configurations.

## Test Scripts

### `lint-scripts.sh` - Local Validation

Validates JavaScript syntax and Shelly compatibility **without requiring device access**.

```bash
./tests/lint-scripts.sh
```

**Checks:**
- JavaScript syntax (via Node.js)
- File size (Shelly ~32KB limit)
- Unsupported ES6+ features
- Required Shelly APIs
- Hardcoded device IDs

### `test-deployment.sh` - Full Test Suite

Tests deployed configuration and scripts on actual Shelly devices.

```bash
# Test all devices (config validation only)
./tests/test-deployment.sh all

# Test with functional tests (actually toggles the sauna!)
./tests/test-deployment.sh all --functional

# Test specific device
./tests/test-deployment.sh primary
./tests/test-deployment.sh secondary
```

**Tests included:**
| Test | Description |
|------|-------------|
| Connectivity | Can reach device via HTTP |
| JS Syntax | Local syntax validation |
| Script Running | Verify script is executing |
| Input Config | Correct input modes (button/switch) |
| Switch Config | Relay names, default states |
| Virtual Button | HA integration button exists |
| MQTT Connection | Broker connected |
| **SAFETY: Default OFF** | Relays default to OFF |
| **SAFETY: Auto-off** | Firmware backup timer (secondary) |
| Functional Toggle | Actually toggles and verifies state |

### `validate-config.sh` - Config Comparison

Compares actual device configuration against expected values from `config.json`.

```bash
./tests/validate-config.sh shellypro2-0cb815fcaff4.local
```

Outputs diff between expected and actual configuration.

## Usage Workflow

```bash
# 1. Before deployment - validate scripts locally
./tests/lint-scripts.sh

# 2. After deployment - verify configuration
./tests/test-deployment.sh all

# 3. Optional - run functional test (toggles sauna)
./tests/test-deployment.sh primary --functional

# 4. Debug config issues - compare actual vs expected
./tests/validate-config.sh shellypro2-0cb815fcaff4.local
```

## Requirements

- **Node.js** - For JavaScript syntax validation
- **Python 3** - For JSON parsing
- **curl** - For RPC calls to devices
- **Network access** - To reach Shelly devices on local network
