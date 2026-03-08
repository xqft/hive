#!/bin/bash
# Mock docker CLI for Container lifecycle tests.
# Handles: run, wait, stop, rm, kill, cp, exec, image inspect, ps subcommands.
# Behavior controlled via environment variables:
#   MOCK_DOCKER_EXIT_CODE - exit code for 'wait' (default: 0)
#   MOCK_DOCKER_SLEEP - seconds to sleep during 'wait' (default: 0)

case "$1" in
  run)
    # Extract container name from args
    NAME=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name) NAME="$2"; shift 2 ;;
        -d) shift ;; # detached mode — just skip
        *) shift ;;
      esac
    done
    # Print container ID (docker run -d prints the container ID)
    echo "$NAME"
    exit 0
    ;;

  wait)
    # Simulate waiting for a container to exit
    SLEEP="${MOCK_DOCKER_SLEEP:-0}"
    if [ "$SLEEP" != "0" ]; then
      sleep "$SLEEP"
    fi
    # Print the exit code (docker wait prints the exit code)
    echo "${MOCK_DOCKER_EXIT_CODE:-0}"
    exit 0
    ;;

  stop)
    # Just succeed
    exit 0
    ;;

  rm)
    # Just succeed
    exit 0
    ;;

  kill)
    # Just succeed
    exit 0
    ;;

  cp)
    # If copying last_output.txt, create the destination file with mock content
    if [[ "$2" == *"last_output.txt"* ]]; then
      DEST="$3"
      echo "mock terminal output" > "$DEST"
    fi
    exit 0
    ;;

  exec)
    # Handle exec subcommands
    shift # consume 'exec'
    # Skip container name
    shift
    case "$1" in
      tmux)
        case "$2" in
          has-session)
            exit 0
            ;;
          send-keys)
            exit 0
            ;;
          capture-pane)
            echo "mock terminal output"
            exit 0
            ;;
          list-windows)
            echo "0:main"
            exit 0
            ;;
          new-window)
            exit 0
            ;;
          resize-window)
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
        ;;
      *)
        exit 0
        ;;
    esac
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
