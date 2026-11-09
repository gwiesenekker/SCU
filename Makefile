FPC ?= fpc
FPCFLAGS ?= -O2

.PHONY: all test format-commands clean
all: build/scu build/commands.json

build/scu: $(wildcard src/*.pas) | build
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build src/scu.pas

build/commands.json: commands.json | build
	cp $< $@

build:
	mkdir -p $@

test: all
	python3 tests/integration.py ./build/scu

format-commands:
	python3 tools/format_commands.py commands.json

clean:
	rm -rf build
