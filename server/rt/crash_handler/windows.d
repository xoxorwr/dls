module rt.crash_handler.windows;

pragma(lib, "dbghelp.lib");
import core.sys.windows.windows;
import core.sys.windows.dbghelp;
import core.stdc.stdlib: free, calloc;
import core.stdc.stdio: fprintf, stderr;
import core.stdc.string: memcpy, strncmp, strlen;


extern(C) export void rt_register_crash_handler(const(char)* filename)
{
    SetUnhandledExceptionFilter(&TopLevelExceptionHandler); 
}

private:

struct SYMBOL_INFO {
    ULONG SizeOfStruct;
    ULONG TypeIndex;
    ULONG64[2] Reserved;
    ULONG Index;
    ULONG Size;
    ULONG64 ModBase;
    ULONG Flags;
    ULONG64 Value;
    ULONG64 Address;
    ULONG Register;
    ULONG Scope;
    ULONG Tag;
    ULONG NameLen;
    ULONG MaxNameLen;
    CHAR[1] Name;
}
extern(Windows) USHORT RtlCaptureStackBackTrace(ULONG FramesToSkip, ULONG FramesToCapture, PVOID *BackTrace, PULONG BackTraceHash);
extern(Windows) BOOL SymFromAddr(HANDLE hProcess, DWORD64 Address, PDWORD64 Displacement, SYMBOL_INFO* Symbol);
extern(Windows) BOOL SymGetLineFromAddr64(HANDLE hProcess, DWORD64 dwAddr, PDWORD pdwDisplacement, IMAGEHLP_LINEA64 *line);

extern(Windows)LONG TopLevelExceptionHandler(PEXCEPTION_POINTERS pExceptionInfo)
{
    fprintf(stderr, "-------------------------------------------------------------------+\r\n");
    fprintf(stderr, "Received signal '%s' (%ull)\r\n", "exception".ptr, pExceptionInfo.ExceptionRecord.ExceptionCode);
    fprintf(stderr, "-------------------------------------------------------------------+\r\n");

    enum MAX_DEPTH = 32;
    void*[MAX_DEPTH] stack;

    HANDLE process = GetCurrentProcess();

    SymInitialize(process, null, true);
    SymSetOptions(SYMOPT_LOAD_LINES);

    ushort frames = RtlCaptureStackBackTrace(0, MAX_DEPTH, stack.ptr, null);
    SYMBOL_INFO* symbol = cast(SYMBOL_INFO*) calloc((SYMBOL_INFO.sizeof) + 256 * char.sizeof, 1);
    symbol.MaxNameLen = 255;
    symbol.SizeOfStruct = SYMBOL_INFO.sizeof;

    IMAGEHLP_LINEA64 line = void;
    line.SizeOfStruct = SYMBOL_INFO.sizeof;

    DWORD dwDisplacement;

    for (uint i = 0; i < frames; i++)
    {
        SymFromAddr(process, cast(DWORD64)(stack[i]), null, symbol);
        SymGetLineFromAddr64(process, cast(DWORD64)(stack[i]), &dwDisplacement, &line);

        // auto f = frames - i - 1;
        auto funcName = symbol.Name.ptr;
        auto fname = line.FileName;
        auto lnum = line.LineNumber;

        if (ends_with(fname, __FILE__)) continue; // skip trace from this module


        // import core.demangle: demangle;
        fprintf(stderr, "%s:%i - %s\n", fname, lnum, funcName);
    }
    free(symbol);
    return EXCEPTION_CONTINUE_SEARCH;
}

int ends_with(const(char)* str, const(char)* suffix)
{
    if (!str || !suffix)
        return 0;
    size_t lenstr = strlen(str);
    size_t lensuffix = strlen(suffix);
    if (lensuffix >  lenstr)
        return 0;
    return strncmp(str + lenstr - lensuffix, suffix, lensuffix) == 0;
}

