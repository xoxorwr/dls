module rt.crash_handler;

version (Windows)
    public import rt.crash_handler.windows;
else version (Posix)
    public import rt.crash_handler.posix;
else
    public import rt.crash_handler.none;
