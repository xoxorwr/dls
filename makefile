# Builds dls, the D language server -> bin/dls (bin/dls.exe on Windows).
#
#   make                 # debug build
#   make MODE=RELEASE    # optimized build
#   make test            # build everything, then run the end-to-end suite
#   make build-vscode    # package the VS Code extension (needs npm)
#   make clean
#
# bin/dls compiles the DCD sources under dcd_templates/src directly alongside
# the server into a single binary. It defaults to ldmd2, LDC's dmd-compatible
# driver.

ifeq ($(origin DC),environment)
DC := ldmd2
else
DC ?= ldmd2
endif
MODE ?= DEBUG
PREVIEWS := -preview=rvaluerefparam -preview=bitfields

ifeq ($(OS),Windows_NT)
    EXE := .exe
else
    EXE :=
endif

ifeq ($(MODE), RELEASE)
    OPTIMIZE := -release -O3
else
    OPTIMIZE := -g
endif

DCD_SRC := $(shell find dcd_templates/src -name '*.d')
SERVER_SRC := $(shell find server -name '*.d')
BUILD_FLAGS := $(OPTIMIZE) $(PREVIEWS) -version=built_with_dub -Iserver/ -Idcd_templates/src

VSCODE_DIR := editors/vscode

.PHONY: all dls test build-vscode windows clean

all: dls

# The server, compiling DCD directly from source -> bin/dls[.exe].
dls:
	@mkdir -p bin
	$(DC) -of=bin/dls$(EXE) $(BUILD_FLAGS) -i server/dls/main.d $(DCD_SRC)

test: dls
	python3 run_tests.py

# Windows binary, for testing the parts of the server that only differ there
# (the C runtime's text mode, the share mode a handle asks for, the lexer on a
# CRLF or BOM file). Override WIN_DC / WINEPREFIX when your setup differs.
WINEPREFIX ?= $(HOME)/.wine
WIN_DC ?= C:/D/ldc2/bin/ldmd2.exe

export WINEPREFIX

windows: bin/dls.exe

bin/dls.exe: $(DCD_SRC) $(SERVER_SRC)
	@mkdir -p bin
	wine $(WIN_DC) -of=bin/dls.exe $(OPTIMIZE) -preview=rvaluerefparam \
	    -preview=bitfields -version=built_with_dub -i -Iserver -Idcd_templates/src server/dls/main.d $(DCD_SRC)

build-vscode:
	cd $(VSCODE_DIR) && npm ci
	cd $(VSCODE_DIR) && npm run compile
	cd $(VSCODE_DIR) && npm run package
	@mkdir -p bin
	mv $(VSCODE_DIR)/*.vsix bin/

clean:
	rm -f bin/dls bin/dls.exe bin/dls.o

