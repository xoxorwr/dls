# Builds the DCD static library the dls server links against.
#
# This used to be a small dub project; only the static library is wanted, so
# it is a plain makefile now.  Every module under src/ is compiled into one
# archive (the dcd client/server executables are not built), which is all the
# server needs - it talks to dcd through the extern(C) entry points in
# src/dcd/server/dll.d.
#
#   make                 # debug library
#   make MODE=RELEASE    # optimized library
#   make clean
#
# Use the same compiler as the server (see the top-level makefile): the two
# must share one D runtime to link together.

DC ?= ldmd2
MODE ?= DEBUG
PREVIEWS := -preview=bitfields
VERSIONS := -version=built_with_dub

# LDC's command line parser only recognizes `.lib` on Windows, `.a` elsewhere.
ifeq ($(OS),Windows_NT)
    LIB := libdcd.lib
else
    LIB := libdcd.a
endif

ifeq ($(MODE), RELEASE)
    OPTIMIZE := -release -O3
else
    OPTIMIZE := -debug -g
endif

SRC := $(shell find src -name '*.d')

.PHONY: all clean

# Always rebuild: the compile flags (-debug/-release) are not recorded in the
# archive, so a timestamp check would silently reuse a library built for the
# other mode.  A full build only takes a few seconds.
all:
	$(DC) -lib -of=$(LIB) $(OPTIMIZE) -w $(VERSIONS) -Isrc $(SRC) $(PREVIEWS) -vcolumns

clean:
	rm -f libdcd.a libdcd.lib
