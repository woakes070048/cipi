#!/bin/bash
#############################################
# Cipi Migration 4.6.7 — APT/dpkg lock timeout
#
# Fresh installs get this from setup.sh; existing servers need the persistent
# apt.conf snippet so cipi php install / self-update tolerate unattended-upgrades.
#
# Idempotent — safe to re-run.
#############################################

set -e

echo "Migration 4.6.7 — APT lock timeout (300s)..."

cat > /etc/apt/apt.conf.d/00cipi-lock-timeout <<'EOF'
DPkg::Lock::Timeout "300";
EOF

echo "  Wrote /etc/apt/apt.conf.d/00cipi-lock-timeout"
echo "Migration 4.6.7 complete"
