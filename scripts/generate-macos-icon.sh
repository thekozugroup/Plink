#!/usr/bin/env bash
set -euo pipefail
exec swift "$(dirname "$0")/generate-macos-icon.swift"
