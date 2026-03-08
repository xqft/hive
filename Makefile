-include .env
export

.PHONY: setup deps compile test test-sdk test-docker server iex docker-build clean

# Full project setup
setup: deps
	cd sdk && npm install
	mix compile
	mix assets.setup
	mix assets.build

# Install Elixir dependencies
deps:
	mix deps.get

# Compile
compile:
	mix compile

# Run tests
test:
	mix test

# Run JS SDK tests
test-sdk:
	cd sdk && npm test

# Build and verify Docker image
test-docker:
	docker build -t hive-claude-code:test -f docker/Dockerfile.claude-code .
	docker run --rm --entrypoint sh hive-claude-code:test -c 'claude --version'

# Start Phoenix server
server:
	iex -S mix phx.server

# Interactive Elixir shell
iex:
	iex -S mix

# Build Docker image for container execution
docker-build:
	docker build -t hive-claude-code:latest -f docker/Dockerfile.claude-code .

# Clean build artifacts
clean:
	mix clean
	rm -rf _build deps
