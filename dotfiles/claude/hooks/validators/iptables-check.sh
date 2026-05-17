#!/bin/bash
# iptables command validator
# Checks syntax before executing on Oracle VPS (especially position 6 rules)

set -euo pipefail

COMMAND="${1:-}"

if [ -z "$COMMAND" ]; then
  echo "❌ No iptables command specified"
  exit 1
fi

echo "🔍 Validating iptables command"
echo "   Command: $COMMAND"

# Common errors
ERRORS=()
WARNINGS=()

# Check for position 6 (Oracle Cloud specific)
if echo "$COMMAND" | grep -qE '\-A INPUT|\-I INPUT'; then
  if echo "$COMMAND" | grep -q '\-A INPUT'; then
    WARNINGS+=("Oracle VPS requires '-I INPUT 6' instead of '-A INPUT' for ingress rules")
  elif ! echo "$COMMAND" | grep -q '\-I INPUT 6'; then
    WARNINGS+=("Oracle VPS requires '-I INPUT 6' (missing position number)")
  fi
fi

# Check for required flags
if echo "$COMMAND" | grep -qE '\-A INPUT|\-I INPUT'; then
  if ! echo "$COMMAND" | grep -q '\-j'; then
    ERRORS+=("Missing jump target (-j ACCEPT|DROP|REJECT)")
  fi
  if ! echo "$COMMAND" | grep -qE '\-p tcp|\-p udp|\-p icmp'; then
    WARNINGS+=("No protocol specified (-p tcp|udp|icmp)")
  fi
fi

# Block flush/delete — too dangerous without explicit confirmation
if echo "$COMMAND" | grep -qE '\-F\b|--flush\b'; then
  ERRORS+=("FLUSH wipes all rules — will break VPS connectivity. Confirm explicitly with user.")
fi
if echo "$COMMAND" | grep -qE '\-D\s+INPUT'; then
  WARNINGS+=("DELETE (-D) removes an existing rule — verify rule number/spec is correct")
fi

if echo "$COMMAND" | grep -qE '(--dport|--sport)\s+22.*DROP|DROP.*(--dport|--sport)\s+22'; then
  ERRORS+=("🚨 BLOCKING SSH PORT 22 - This will lock you out!")
fi

# Check for typos
if echo "$COMMAND" | grep -qE 'iptalbes|iptabe|iptable\s'; then
  ERRORS+=("Typo in command name")
fi

# Report findings
if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "❌ iptables validation failed:"
  for err in "${ERRORS[@]}"; do
    echo "   • $err"
  done
  exit 1
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo "⚠️  Warnings:"
  for warn in "${WARNINGS[@]}"; do
    echo "   • $warn"
  done
fi

echo "✅ iptables validation passed"
echo "   Safe to execute on VPS"
exit 0
