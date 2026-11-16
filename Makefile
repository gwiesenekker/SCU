FPC ?= fpc
FPCFLAGS ?= -O2
LAZBUILD ?= lazbuild

.PHONY: all test gui test-gui format-commands clean
all: build/scu build/commands.json

build/scu: $(wildcard src/*.pas) | build
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build src/scu.pas

build/commands.json: commands.json | build
	cp $< $@

build:
	mkdir -p $@

build/executor_probe: tests/executor_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/executor_probe.pas

build/platform_probe: tests/platform_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/platform_probe.pas

build/files_probe: tests/files_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/files_probe.pas

test: all build/executor_probe build/platform_probe build/files_probe
	python3 tests/platform.py ./build/platform_probe
	python3 tests/files.py ./build/files_probe
	python3 tests/integration.py ./build/scu

format-commands:
	python3 tools/format_commands.py commands.json

clean:
	rm -rf build

# Optional native frontend; the CLI build has no Lazarus dependency.
gui: all
	$(LAZBUILD) --widgetset=gtk2 gui/scu_gui.lpi

test-gui: gui
	$(LAZBUILD) --widgetset=gtk2 tests/gui_check.lpi
	python3 tests/gui_integration.py
