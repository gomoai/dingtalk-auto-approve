#!/bin/bash
# OpenClaw skill lifecycle: install
# Wrapper around setup.sh so agents can call a stable action name.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="${1:-${DEPLOY_DIR:-$HOME/dingtalk-auto-approve}}"

export OPENCLAW_AUTO="${OPENCLAW_AUTO:-1}"
export SETUP_CRON="${SETUP_CRON:-y}"

exec bash "$SCRIPT_DIR/setup.sh" "$DEPLOY_DIR"
