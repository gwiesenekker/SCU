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

build/locks_probe: tests/locks_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/locks_probe.pas

build/process_probe: tests/process_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/process_probe.pas

build/terminal_probe: tests/terminal_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/terminal_probe.pas

build/sqlite_probe: tests/sqlite_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/sqlite_probe.pas

build/scan_probe: tests/scan_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/scan_probe.pas

build/cleanup_probe: tests/cleanup_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/cleanup_probe.pas

build/dll_probe: tests/dll_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/dll_probe.pas

build/actor_probe: tests/actor_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/actor_probe.pas

build/export_names_probe: tests/export_names_probe.pas build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build tests/export_names_probe.pas

test: all build/executor_probe build/platform_probe build/files_probe build/locks_probe build/process_probe build/terminal_probe build/sqlite_probe build/scan_probe build/cleanup_probe build/dll_probe build/actor_probe build/export_names_probe
	python3 tests/export_names.py ./build/export_names_probe
	python3 tests/actors.py ./build/actor_probe
	python3 tests/dlls.py ./build/dll_probe
	python3 tests/cleanup.py ./build/cleanup_probe
	python3 tests/scanning.py ./build/scan_probe
	python3 tests/sqlite.py ./build/sqlite_probe
	python3 tests/platform.py ./build/platform_probe
	python3 tests/files.py ./build/files_probe
	python3 tests/locks.py ./build/locks_probe
	python3 tests/processes.py ./build/process_probe
	python3 tests/terminal.py ./build/terminal_probe
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
