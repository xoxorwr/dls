module rt.io;

public import rt.io.reader;
public import rt.io.writer;
public import rt.io.binary;
public import rt.io.stream;

import rt.fmt: format;



version (NONE) mixin template implement(T)
{
    //const(char)[] implement = "__gshared VT VT = {" ~ "};";
    mixin("__gshared T.VT VT = {" ~ build_init!T ~ "};\n"~build_impl!T);


    static string build_init(T)()
    {
        string ret = "";
        static foreach(it; __traits(allMembers, T.VT))
        {
            ret ~= it~ ": &"~ it~"_impl,";
        }

        return ret;
    }
    static string build_impl(T)()
    {
        string ret = "";
        //return "write: " ~ "null";

        static foreach(it; __traits(allMembers, T.VT))
        {

            pragma(msg, params);

            ret ~= "static void "~ it~"_impl( void* ptr, char[] data )\n{" ~

            	"return (cast(typeof(this)*) ptr).write(data);"

            ~ "}";
        }

        return ret;
    }
}



void writeln(Char, Args...)(in Char[] fmt, Args args)
{
    StdOutStream stream;
    format(stream.writer(), fmt, args);
    format(stream.writer(), "\n");

    version(WebAssembly)
    {}
    else
    {
        fflush(stdout);
    }
}

void write(Char, Args...)(in Char[] fmt, Args args)
{
    StdOutStream stream;
    format(stream.writer(), fmt, args);
}



version(WebAssembly)
{
    import rt.wasm;
}
else
{
    import core.stdc.stdio: printf, fprintf, fflush, stdout, stderr;
}


void test()
{

}

struct StdOutStream
{
    __gshared Writer.VT VT_W = {write: &write_impl,};
    static size_t write_impl( void* ptr, scope ubyte[] data )
    {return (cast(StdOutStream*) ptr).write(data);}

    __gshared Reader.VT VT_R = {read: &read_impl,};
    static size_t read_impl( void* ptr, ubyte[] dest )
    {return (cast(StdOutStream*) ptr).read(dest);}


    ubyte[] buffer;
    size_t pos;

    size_t write(scope ubyte[] data)
    {
        version(WebAssembly)
        {
            print_str_len(cast(char*) data.ptr, data.length);
        }
        else
        {
            fprintf(stderr, "%.*s", cast(int) data.length, cast(char*) data.ptr);
        }
        return data.length;
    }

    size_t read(ubyte[] dest)
    {
        assert(0, "fuck off");
    }

    Writer writer()
    {
        return Writer(&this, VT_W);
    }
}
