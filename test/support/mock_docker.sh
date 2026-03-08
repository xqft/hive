#!/bin/bash
# Mock docker CLI for Container lifecycle tests.
# Handles: run, kill, image inspect, ps subcommands.
# Behavior controlled via environment variables:
#   MOCK_DOCKER_EXIT_CODE - exit code for 'run' (default: 0)
#   MOCK_DOCKER_SLEEP - seconds to sleep during 'run' (default: 0)
#   MOCK_DOCKER_OUTPUT - output lines during 'run' (default: "mock output line")

case "$1" in
  run)
    # Extract container name from args
    NAME=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name) NAME="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    # Output lines
    OUTPUT="${MOCK_DOCKER_OUTPUT:-mock output line}"
    echo "$OUTPUT"

    # Sleep if requested (for timeout tests)
    SLEEP="${MOCK_DOCKER_SLEEP:-0}"
    if [ "$SLEEP" != "0" ]; then
      sleep "$SLEEP"
    fi

    exit "${MOCK_DOCKER_EXIT_CODE:-0}"
    ;;

  kill)
    # Just succeed
    exit 0
    ;;

  image)
    if [ "$2" = "inspect" ]; then
      echo "[{\"Id\": \"mock-image\"}]"
      exit 0
    fi
    exit 1
    ;;

  ps)
    # Return empty (no orphan containers)
    exit 0
    ;;

  *)
    echo "mock_docker: unknown command $1" >&2
    exit 1
    ;;
esac
