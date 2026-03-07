.PHONY: setup deps compile test server iex docker-build clean

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
