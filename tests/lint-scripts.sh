#!/bin/bash
# =============================================================================
# LINT AND VALIDATE SHELLY SCRIPTS LOCALLY
# =============================================================================
# Validates JavaScript syntax and checks for common issues before deployment.
#
# Usage: ./lint-scripts.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

echo "=============================================="
echo "  SHELLY SCRIPT LINTING"
echo "=============================================="
echo ""

ERRORS=0

lint_script() {
    local file="$1"
    local name="$2"
    
    echo "Checking: $name"
    echo "  File: $file"
    
    if [ ! -f "$file" ]; then
        echo "  ✗ ERROR: File not found"
        ((ERRORS++))
        return
    fi
    
    # Check file size (Shelly has ~32KB limit)
    local size=$(wc -c < "$file" | tr -d ' ')
    if [ "$size" -gt 32000 ]; then
        echo "  ✗ ERROR: Script too large ($size bytes, max ~32KB)"
        ((ERRORS++))
    else
        echo "  ✓ Size OK: $size bytes"
    fi
    
    # JavaScript syntax check (requires Node.js)
    if command -v node &> /dev/null; then
        if node --check "$file" 2>/dev/null; then
            echo "  ✓ JavaScript syntax valid"
        else
            echo "  ✗ ERROR: JavaScript syntax errors:"
            node --check "$file" 2>&1 | sed 's/^/    /'
            ((ERRORS++))
        fi
    else
        echo "  ○ SKIP: Node.js not installed - cannot validate syntax"
    fi
    
    # Check for common Shelly-specific issues
    echo "  Checking Shelly compatibility..."
    
    # Check for unsupported ES6+ features (Shelly uses limited JS)
    if grep -q "async\|await" "$file"; then
        echo "    ⚠ WARNING: Found async/await - may not be supported"
    fi
    
    if grep -q "import\|export" "$file"; then
        echo "    ✗ ERROR: ES6 modules (import/export) not supported"
        ((ERRORS++))
    fi
    
    if grep -q "class " "$file"; then
        echo "    ⚠ WARNING: Classes may have limited support"
    fi
    
    # Check for required Shelly APIs
    if grep -q "Shelly.call" "$file"; then
        echo "    ✓ Uses Shelly.call API"
    fi
    
    if grep -q "Timer.set" "$file"; then
        echo "    ✓ Uses Timer API"
    fi
    
    if grep -q "MQTT.publish" "$file"; then
        echo "    ✓ Uses MQTT API"
    fi
    
    # Check for hardcoded device IDs (should match hardware config)
    local device_ids=$(grep -oE 'shellypro2-[a-f0-9]+' "$file" | sort -u)
    if [ -n "$device_ids" ]; then
        echo "    Device IDs found:"
        echo "$device_ids" | sed 's/^/      - /'
    fi
    
    echo ""
}

# Lint all scripts
lint_script "$PROJECT_ROOT/devices/shelly-primary/script.js" "Primary Control Script"
lint_script "$PROJECT_ROOT/devices/shelly-secondary/script.js" "Secondary Safety Script"

# Summary
echo "=============================================="
echo "  SUMMARY"
echo "=============================================="

if [ $ERRORS -eq 0 ]; then
    echo "✓ All scripts passed validation"
    exit 0
else
    echo "✗ Found $ERRORS error(s)"
    exit 1
fi
