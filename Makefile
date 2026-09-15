# The runtime binary. The shell runs only on a build of the runtime fork
# (wippy-windows/runtime, branch wippy-projects): point WIPPY at it.
WIPPY ?= wippy

.PHONY: run windows test lint

## the web platform on 127.0.0.1:8099 and the SSH desktop on :2222
run:
	$(WIPPY) run

## the desktop in this terminal (the whole runtime comes up with it)
windows:
	$(WIPPY) run --host windows.shell:terminal windows

## boots the whole application
test:
	$(WIPPY) test --host wippy.terminal:host

lint:
	$(WIPPY) lint
