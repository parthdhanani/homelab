#!/bin/bash

# /g skill — query Gemini CLI directly

if [[ -z "$1" ]]; then
  echo "Usage: /g <query>"
  exit 1
fi

# Pass all arguments as the query to gemini
gemini "$@"
