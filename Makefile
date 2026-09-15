# The runtime binary. The shell runs only on a build of the runtime fork
# (chicago-desktop/runtime, branch wippy-projects): `make runtime` downloads
# the latest release into bin/, or point WIPPY at a build of your own.
WIPPY ?= ./bin/wippy
RUNTIME_REPO ?= chicago-desktop/runtime
RUNTIME_TAG ?= latest
GOOS ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
GOARCH ?= $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

.PHONY: run windows test lint runtime

## download the runtime fork's release binary for this machine into bin/wippy
runtime:
	mkdir -p bin
	@if [ "$(RUNTIME_TAG)" = "latest" ]; then \
	  url="https://github.com/$(RUNTIME_REPO)/releases/latest/download/wippy-$(GOOS)-$(GOARCH)"; \
	else \
	  url="https://github.com/$(RUNTIME_REPO)/releases/download/$(RUNTIME_TAG)/wippy-$(GOOS)-$(GOARCH)"; \
	fi; \
	echo "downloading $$url"; curl -fL --progress-bar -o bin/wippy "$$url"
	chmod +x bin/wippy
	./bin/wippy version

## the web platform on 127.0.0.1:8099 and the SSH desktop on :2222
run:
	$(WIPPY) run

## the desktop in this terminal (the whole runtime comes up with it)
windows:
	$(WIPPY) run --host chicago.shell:terminal chicago

## boots the whole application
test:
	$(WIPPY) test --host wippy.terminal:host

lint:
	$(WIPPY) lint
