module rt.crash_handler;

// The handler walks `link_map`s and glibc's ucontext layout.
version (Windows)
    public import rt.crash_handler.windows;
else version (linux)
    public import rt.crash_handler.linux;
else
    public import rt.crash_handler.none;
