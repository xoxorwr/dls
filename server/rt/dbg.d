module rt.dbg;

import rt.io;

version = DBG_PRINT_PATH;
version = DBG_FILE_ONLY;
//version = DBG_COLOR;

struct LogFlag
{
    bool info: 1;
    bool warn: 1;
    bool erro: 1;
}

__gshared LogFlag LOG_FLAG;


version(WebAssembly)
{
    import rt.wasm: abort;
}
else
{
    import core.stdc.stdlib: abort;
}



noreturn not_implemented(string file = __MODULE__, int line = __LINE__)
{
    panic("not implemented at {}:{}", file, line);
}

noreturn panic(Char, A...)(in Char[] fmt, A args, string file = __MODULE__, int line = __LINE__)
{
    set_color(RED);

    DBG_PRINT_PATH(file, line);
    writeln(fmt, args);

    set_color(RESET);

    abort();
}

void assertf(Char, A...)(bool condition, in Char[] fmt, A args, string file = __MODULE__, int line = __LINE__)
{
    if (!condition)
        panic(fmt, args, file, line);
}

void LINFO(Char, A...)(in Char[] fmt, scope A args, string file = __MODULE__, int line = __LINE__)
{
    if (LOG_FLAG.info == false) return;

    set_color(RESET);
    write("[INFO] ");

    version (DBG_PRINT_PATH)
    {
        set_color(GRAY);
        DBG_PRINT_PATH(file, line);
    }

    set_color(RESET);
    writeln(fmt, args);
}

void LWARN(Char, A...)(in Char[] fmt, scope A args, string file = __MODULE__, int line = __LINE__)
{
    if (LOG_FLAG.warn == false) return;
    set_color(YELLOW);
    write("[WARN] ");

    version (DBG_PRINT_PATH)
    {
        set_color(GRAY);
        DBG_PRINT_PATH(file, line);
    }

    set_color(RESET);
    writeln(fmt, args);
}

void LERRO(Char, A...)(in Char[] fmt, scope A args, string file = __MODULE__, int line = __LINE__)
{
    if (LOG_FLAG.erro == false) return;
    set_color(RED);
    write("[ERRO] ");

    version (DBG_PRINT_PATH)
    {
        set_color(GRAY);
        DBG_PRINT_PATH(file, line);
    }

    set_color(RESET);
    writeln(fmt, args);
}

mixin template BENCH(const(char)[] tag)
{
    auto _b = _bench(__FILE__, __LINE__, tag);
}

struct _bench
{
    import time = rt.time;
    const(char)[] __tag;
    const(char)[] __file;
    int __line;

    time.Timespan __start;
    time.Timespan __end;

    this(const(char)[] f, int l, const(char)[] t)
    {
        this.__file = f;
        this.__line = l;
        this.__tag = t;
        __start = time.now();
        __end = __start;
    }

    ~this()
    {
        __end = time.now();
        LWARN(">> {}:{} | {} | took: {} ms", __file, __line, __tag, (__end.msecs() - __start.msecs()));
    }
}

package:

void DBG_PRINT_PATH(string file, int line)
{
    auto fp = cast(char[])file[0 .. $];

    version (DBG_FILE_ONLY)
    {
        int strncmp(const (char) *_l, const (char) *_r, size_t n)
        {
            const (ubyte) *l=cast(ubyte *)_l;
            const (ubyte) *r=cast(ubyte *)_r;
            if (!n--) return 0;
            for (; *l && *r && n && *l == *r ; l++, r++, n--){}
            return *l - *r;
        }
        for (auto i = fp.length-1; i > 0; i--)
        {
            version (Windows)
                char sep = '\\';
            else
                char sep = '/';

            if (file[i] == sep)
            {
                fp = fp[i+1 .. $];
                break;
            }
        }

        // `package.d` is not useful, get the package name instead
        if (strncmp(fp.ptr, "package.d", 9) == 0) {
            bool firstSlash = false;
            for (int i = cast(int)file.length - 1; i > 0; i--) {
                if (file[i] == '/' && !firstSlash) {
                    firstSlash = true;
                }
                else if (file[i] == '/' && firstSlash) {
                    fp = cast(char[])file[i + 1 .. $];
                    break;
                }
            }
        }

    }

    write("[ {}:{} ] ", fp, line);

}

version(Windows)
{
    enum RESET   = 7;
    enum RED     = 12;
    enum GREEN   = 2;
    enum YELLOW  = 14;
    enum BLUE    = 1;
    enum PINK    = 5;
    enum CYAN    = 3;
    enum WHITE   = 15;
    enum GRAY    = 8;

    void set_color(short color)
    {
        import core.sys.windows.winbase;
        import core.sys.windows.wincon;
        auto hConsole = GetStdHandle(STD_OUTPUT_HANDLE);

        SetConsoleTextAttribute(hConsole, color);
    }
}
else
{
    enum RESET = "\033[0m";
    enum RED = "\033[1;31m";
    enum GREEN = "\033[1;32m";
    enum YELLOW = "\033[1;33m";
    enum BLUE = "\033[1;34m";
    enum PINK = "\033[1;35m";
    enum CYAN = "\033[1;36m";
    enum WHITE = "\033[1;37m";
    enum GRAY = "\033[1;90m";

    void set_color(const(char)* color)
    {
        version (DBG_COLOR)
        version(Posix)
            write("{}",color);
    }
}
