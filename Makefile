FPC ?= fpc
FPCFLAGS ?= -O2
LAZBUILD ?= lazbuild
FPCRES ?= fpcres

.PHONY: all test test-portable gui test-gui format-commands clean
all: build/scu build/commands.json

src/scucommands.res: commands.json src/scucommands.rc tools/embed_commands.py
	python3 tools/embed_commands.py --fpcres "$(FPCRES)"

# FPC links resources from the unit output directory on incremental builds.
build/scucommands.res: src/scucommands.res | build
	cp $< $@

.PHONY: FORCE
build/scucommit.inc: FORCE tools/build_id.py | build
	python3 tools/build_id.py $@

build/scu: build/scucommit.inc $(wildcard src/*.pas) build/scucommands.res | build
	$(FPC) $(FPCFLAGS) -Fu./src -FU./build -FE./build -Fi./build src/scu.pas

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

build/gui_process_probe: tests/gui_process_probe.pas $(wildcard gui/*.pas) build/scu
	$(FPC) $(FPCFLAGS) -Fu./src -Fu./gui -FU./build -FE./build tests/gui_process_probe.pas

test: all build/executor_probe build/platform_probe build/files_probe build/locks_probe build/process_probe build/terminal_probe build/sqlite_probe build/scan_probe build/cleanup_probe build/dll_probe build/actor_probe build/export_names_probe build/gui_process_probe
	python3 tools/embed_commands.py --check --fpcres "$(FPCRES)"
	python3 tests/embedded_commands.py
	python3 tests/gui_process.py ./build/gui_process_probe
	python3 tests/windows_build.py
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

test-portable: all
	python3 tests/portable_cli.py ./build/scu

format-commands:
	python3 tools/format_commands.py commands.json

clean:
	rm -rf build

# Optional native frontend; the CLI build has no Lazarus dependency.
gui/scumanual.res: gui/scumanual.rc MANUAL.md
	$(FPCRES) -of res $< -o $@

gui: all gui/scumanual.res
	$(LAZBUILD) $(shell test build/scu-gui -nt gui/scumanual.res && test build/scu-gui -nt build/scucommit.inc || echo --build-all) --widgetset=gtk2 gui/scu_gui.lpi

test-gui: gui
	$(LAZBUILD) $(shell test build/gui-check -nt gui/scumanual.res && test build/gui-check -nt build/scucommit.inc || echo --build-all) --widgetset=gtk2 tests/gui_check.lpi
	python3 tests/gui_integration.py
	python3 tests/gui_integration.py --embedded-catalog
