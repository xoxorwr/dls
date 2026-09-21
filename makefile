# Builds dls, the D language server -> bin/dls (bin/dls.exe on Windows).
#
#   make                 # debug build
#   make MODE=RELEASE    # optimized build
#   make test            # build everything, then run the end-to-end suite
#   make build-vscode    # package the VS Code extension (needs npm)
#   make clean
#
# bin/dls links the DCD static library built by dcd_templates/ and calls it
# through extern(C) entry points.  Both halves must be built by the same
# compiler so they share one D runtime - a mismatched pair fails to link with
# undefined `_d_*` symbols - so DC is handed down to the dcd makefile.  It
# defaults to ldmd2, LDC's dmd-compatible driver.

ifeq ($(origin DC),environment)
DC := ldmd2
else
DC ?= ldmd2
endif
MODE ?= DEBUG
PREVIEWS := -preview=rvaluerefparam -preview=bitfields

ifeq ($(OS),Windows_NT)
    EXE := .exe
    DCDLIB := dcd_templates/libdcd.lib
else
    EXE :=
    DCDLIB := dcd_templates/libdcd.a
endif

ifeq ($(MODE), RELEASE)
    OPTIMIZE := -release -O3
else
    OPTIMIZE := -g
endif

VSCODE_DIR := editors/vscode

.PHONY: all dcd dls test build-vscode clean

all: dls

# The DCD static library (always rebuilt; see dcd_templates/makefile).
dcd:
	$(MAKE) -C dcd_templates MODE=$(MODE) DC=$(DC)

# The server, linked against the DCD library -> bin/dls[.exe].
dls: dcd
	@mkdir -p bin
	$(DC) -of=bin/dls$(EXE) $(OPTIMIZE) $(PREVIEWS) -i -Iserver/ \
	    server/dls/main.d $(DCDLIB)

test: dls
	python3 run_tests.py

build-vscode:
	cd $(VSCODE_DIR) && npm ci
	cd $(VSCODE_DIR) && npm run compile
	cd $(VSCODE_DIR) && npm run package
	@mkdir -p bin
	mv $(VSCODE_DIR)/*.vsix bin/

clean:
	rm -f bin/dls bin/dls.exe bin/dls.o
	$(MAKE) -C dcd_templates clean
