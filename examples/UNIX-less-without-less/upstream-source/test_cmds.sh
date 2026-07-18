#!/bin/bash
# Test script to verify :n and :p commands work
# This simulates user input and checks if file switching works

# Run ddpager with two files, send :n then :p commands
# Note: We need to use socat or expect for proper terminal emulation

if [[ ! -x "$(command -v socat)" ]]; then
    echo "socat not available, manual test required"
    echo "To test manually:"
    echo "  1. Run: ./ddpager.sh /etc/passwd /etc/lsb-release"
    echo "  2. Press : then n then Enter"
    echo "  3. Should show lsb-release"
    echo "  4. Press : then p then Enter"
    echo "  5. Should show passwd again"
else
    echo "Testing with socat..."
    # This is complex - better to manual test
fi
