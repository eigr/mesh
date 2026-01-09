.PHONY: help compile clean test format lint docs benchmark benchmark-single benchmark-multi example example-node1 example-node2 deps check all

# Default target
help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Development targets
deps: ## Install dependencies
	mix deps.get
	cd example && mix deps.get

compile: ## Compile the project
	mix compile

clean: ## Clean build artifacts
	mix clean
	rm -rf _build
	rm -rf deps
	cd example && mix clean
	cd example && rm -rf _build
	cd example && rm -rf deps

# Testing
test: ## Run all tests
	mix test

test-watch: ## Run tests in watch mode
	mix test.watch

# Code quality
format: ## Format code with mix format
	mix format
	cd example && mix format

format-check: ## Check if code is formatted
	mix format --check-formatted
	cd example && mix format --check-formatted

lint: ## Run static analysis (requires credo)
	@if mix help credo >/dev/null 2>&1; then \
		mix credo --strict; \
	else \
		echo "Credo not installed. Run: mix archive.install hex credo"; \
	fi

dialyzer: ## Run dialyzer (requires dialyxir)
	@if mix help dialyzer >/dev/null 2>&1; then \
		mix dialyzer; \
	else \
		echo "Dialyxir not installed. Add {:dialyxir, \"~> 1.4\", only: [:dev], runtime: false} to deps"; \
	fi

check: format-check test ## Run format check and tests

# Documentation
docs: ## Generate documentation
	mix docs
	@echo "Documentation generated in doc/index.html"

docs-open: docs ## Generate and open documentation
	@if command -v xdg-open >/dev/null 2>&1; then \
		xdg-open doc/index.html; \
	elif command -v open >/dev/null 2>&1; then \
		open doc/index.html; \
	else \
		echo "Documentation generated in doc/index.html"; \
	fi

# Benchmarks
benchmark: benchmark-single ## Run default benchmark (single-node)

benchmark-single: compile ## Run single-node benchmark
	@echo "Running single-node benchmark..."
	mix run scripts/benchmark_singlenode.exs

benchmark-benchee: compile ## Run Benchee benchmark with detailed statistics
	@echo "Running Benchee benchmark..."
	mix run scripts/benchee_benchmark.exs

benchmark-multi: compile ## Run multi-node benchmark (requires distributed mode)
	@echo "Running multi-node benchmark..."
	@echo "Note: This requires Erlang distribution to be enabled"
	elixir --name bench@127.0.0.1 --cookie mvp -S mix run scripts/benchmark_multinode.exs

test-distributed: compile ## Test distributed mode manually (see scripts/test_distributed.exs)
	@cat scripts/test_distributed.exs
	@echo ""
	@echo "💡 Tip: Open two terminals and follow the guide above"

# Example application
example-deps: ## Install example dependencies
	cd example && mix deps.get

example-compile: example-deps ## Compile example application
	cd example && mix compile

example-shell: example-compile ## Start example application in IEx
	cd example && iex -S mix

example-node1: example-compile ## Start example node 1 (game capability)
	@echo "Starting node1 with :game capability..."
	cd example && elixir --name node1@127.0.0.1 --cookie mesh -S mix

example-node2: example-compile ## Start example node 2 (chat capability)
	@echo "Starting node2 with :chat capability..."
	@echo "In another terminal, run: make example-node1"
	cd example && elixir --name node2@127.0.0.1 --cookie mesh -S mix

example-node3: example-compile ## Start example node 3 (all capabilities)
	@echo "Starting node3 with all capabilities..."
	cd example && elixir --name node3@127.0.0.1 --cookie mesh -S mix

example-clean: ## Clean example build artifacts
	cd example && mix clean
	cd example && rm -rf _build deps

# Complete workflows
all: deps compile test ## Install deps, compile, and test

ci: deps compile format-check test ## Run CI pipeline (deps, compile, format check, test)

dev: compile ## Start development with IEx
	iex -S mix

dev-distributed: compile ## Start development with distributed Erlang
	elixir --name dev@127.0.0.1 --cookie mesh -S mix

# Release
release-check: ## Check if project is ready for release
	@echo "Running release checks..."
	@make format-check
	@make test
	@make docs
	@echo "✅ Release checks passed!"

# Info
info: ## Show project information
	@echo "Mesh - Distributed Actor System"
	@echo "================================"
	@echo ""
	@echo "Project structure:"
	@echo "  lib/           - Main library code"
	@echo "  test/          - Test files"
	@echo "  scripts/       - Benchmark scripts"
	@echo "  example/       - Example application"
	@echo "  docs/guides/   - Documentation guides"
	@echo ""
	@echo "Elixir version: $$(elixir --version | grep Elixir)"
	@echo "Erlang version: $$(elixir --version | grep Erlang)"
	@echo ""
	@echo "Run 'make help' to see all available targets"
