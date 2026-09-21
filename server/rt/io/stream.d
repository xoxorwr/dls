module rt.io.stream;

import rt.dbg;
import rt.io;

struct FixedBufferStream
{
    __gshared Writer.VT VT_W = {write: &write_impl,};
    static size_t write_impl( void* ptr, scope ubyte[] data )
    {return (cast(FixedBufferStream*) ptr).write(data);}

    __gshared Reader.VT VT_R = {read: &read_impl,};
    static size_t read_impl( void* ptr, ubyte[] dest )
    {return (cast(FixedBufferStream*) ptr).read(dest);}


    ubyte[] buffer;
    size_t pos;

    size_t write(scope ubyte[] data)
    {
        if (data.length == 0) return 0;
        if (pos >= buffer.length) return 0;

        auto n = ((pos + data.length) <= buffer.length) ? data.length : buffer.length - pos;

        buffer[pos .. $][0 .. n] = data[0.. $];
        pos += n;

        return n;
    }

    size_t read(ubyte[] dest)
    {
        //const size =  min(dest.length, buffer.length - pos);
        const size =  (dest.length < (buffer.length - pos)) ? dest.length : (buffer.length - pos);
        const end = pos + size;

        dest[0..size] =  buffer[pos..end];
        pos = end;

        return size;
    }

    Writer writer()
    {
        return Writer(&this, VT_W);
    }
    Reader reader()
    {
        return Reader(&this, VT_R);
    }
}


size_t format_to(Char, Args...)(char[] buffer, Char[] fmt, Args args)
{
    import rt.fmt;
    FixedBufferStream stream;
    stream.buffer = cast(ubyte[]) buffer;

    format(stream.writer(), fmt, args);

    return stream.pos;
}