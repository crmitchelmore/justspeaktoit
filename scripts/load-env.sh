#!/bin/bash

# Load environment variables from .env file
# Usage: source scripts/load-env.sh

set -a  # automatically export all variables
if [ -f .env ]; then
    # shellcheck disable=SC1091
    source .env
fi
set +a
