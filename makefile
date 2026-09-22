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

.PHONY: all dcd dls test build-vscode windows clean

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

# Windows binary, for testing the parts of the server that only differ there
# (the C runtime's text mode, the share mode a handle asks for, the lexer on a
# CRLF or BOM file).  On Windows itself plain `make` builds bin/dls.exe; this
# target is for Linux, where the Windows compiler is the one inside a wine
# prefix.  Override WIN_DC / WINEPREFIX when your setup differs.
WINEPREFIX ?= $(HOME)/.wine
# Forward slashes on purpose: make and the shell both eat backslashes, and
# wine takes the path either way.
WIN_DC ?= C:/D/ldc2/bin/ldmd2.exe
WIN_LIB := dcd_templates/libdcd.lib
WIN_DCD_SRC := $(shell find dcd_templates/src -name '*.d')
WIN_SERVER_SRC := $(shell find server -name '*.d')

export WINEPREFIX

windows: bin/dls.exe

bin/dls.exe: $(WIN_DCD_SRC) $(WIN_SERVER_SRC)
	@mkdir -p bin
	wine $(WIN_DC) -lib -of=$(WIN_LIB) $(OPTIMIZE) -w -version=built_with_dub \
	    -Idcd_templates/src $(WIN_DCD_SRC) -preview=bitfields -vcolumns
	wine $(WIN_DC) -of=bin/dls.exe $(OPTIMIZE) -preview=rvaluerefparam \
	    -preview=bitfields -i -Iserver server/dls/main.d $(WIN_LIB)

build-vscode:
	cd $(VSCODE_DIR) && npm ci
	cd $(VSCODE_DIR) && npm run compile
	cd $(VSCODE_DIR) && npm run package
	@mkdir -p bin
	mv $(VSCODE_DIR)/*.vsix bin/

clean:
	rm -f bin/dls bin/dls.exe bin/dls.o
	$(MAKE) -C dcd_templates clean
