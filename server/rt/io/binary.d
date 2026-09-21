module rt.io.binary;

import rt.dbg;

alias StreamLE = Stream!true;
alias StreamBE = Stream!false;

struct Stream(bool LE)
{
    ubyte[] buffer;
    int position;

    this(ubyte[] data)
    {
        buffer = data;
        position = 0;
    }

    bool available()
    {
        return position < buffer.length;
    }

    void skip_all()
    {
        position = cast(int)buffer.length;
    }
    // todo: use that?
    bool check(int amount)
    {
        if(buffer.length < position + amount) return false;
        return true;
    }

    ubyte read_ubyte()
    {
        assert (position < buffer.length);

        ubyte value = buffer[position];
        position++;
        return value;
    }

    byte read_byte()
    {
        assert (position < buffer.length);

        ubyte value = buffer[position];
        position++;
        return value;
    }

    float read_float()
    {
        assert(buffer.length >= this.position + 4);
        ubyte[4] data = buffer[position .. position + 4];
        position += 4;

        static if (LE)
            return *cast(float*) data;
        else
        {
            auto flip = ntoh32(cast(uint*) data);
            return  *cast(float*) &flip;
        }
    }

    int read_int()
    {
        ubyte[4] data = buffer[position .. position + 4];
        position += 4;
        static if (LE)
            return *cast(int*) data;
        else
            return ntoh32(cast(uint*) data);
    }

    int read_compressed_int()
    {
        int b = cast(int) read_byte();
        bool negative = (b & 0x40) != 0;

        auto value = b & 0x3f;
        auto bits = 6;

        while ((b & 0x80) != 0)
        {
            b = read_byte();
            value |= (b & 0x7f) << bits;
            bits += 7;
        }

        if (negative)
        {
            value = -value;
        }
        return value;
    }
    uint read_uint()
    {
        scope ubyte[4] data = buffer[position .. position + 4];
        position += 4;
        static if (LE)
            return *cast(uint*) data;
        else
            return ntoh32(cast(uint*) data);
    }

    long read_long()
    {
        scope ubyte[8] data = buffer[position .. position + 8];
        position += 8;
        static if (LE)
            return *cast(long*) data;
        else
            return ntoh64(cast(ulong*) data);
    }

    ulong read_ulong()
    {
        scope ubyte[8] data = buffer[position .. position + 8];
        position += 8;
        static if (LE)
            return *cast(ulong*) data;
        else
            return ntoh64(cast(ulong*) data);
    }

    short read_short()
    {
        scope ubyte[2] data = buffer[position .. position + 2];
        position += 2;

        static if (LE)
            return *cast(short*) data;
        else
        {
            auto ret = ntoh16(cast(ushort*)data);
            return ret;
        }
    }

    ushort read_ushort()
    {
        scope ubyte[2] data = buffer[position .. position + 2];
        position += 2;
        static if (LE)
            return *cast(ushort*) data;
        else
        {
            auto ret = ntoh16(cast(ushort*)data);
            return ret;
        }
    }

    double read_double()
    {
        scope ubyte[8] data = buffer[position .. position + 8];
        position += 8;
        static if (LE)
            return *cast(double*) data;
        else
            return cast(float) cast(long) ntoh64(cast(ulong*) data);
    }


    const(ubyte)[] read_slice(size_t size)
    {
        auto ret = buffer[position .. position + size];
        position += size;
        return ret;
    }

    void read_to(ubyte[] buffer, size_t size)
    {
        assert(buffer.length >= size);
        auto slice = read_slice(size);

        buffer[0 .. $] = slice[0 .. $];
    }

    // no alloc
    string read_string()
    {
        short l = read_short();
        if(l == 0) return null;

        auto data = read_slice(cast(ushort) l);
        return cast(string) cast(char[]) data;
    }

    string read_cstring()
    {
        //debug_print(position, position + 15);
        auto length = 0;
        for(int i = position; i < buffer.length; i++)
        {
            if(buffer[i] == 0) break;
            length++;
        }
        auto data = read_slice(cast(ushort) length);
        position++;
        return cast(string) cast(char[]) data;
    }

     void read_string_to(char[] str)
     {
        auto s = read_string();
        // TODO: what to do if we have bigger data than str?
        for (int i = 0; i < str.length; i++)
        {
            if(i >= s.length) break;
            str[i] = s[i];
        }
        if(s.length < str.length)
            str[s.length] = 0;
        else
            str[$-1] = 0;
    }

    string read_utf32()
    {
        int l = read_int();
        if(l == 0) return null;

        scope auto data = read_slice(cast(ushort) l);
        return cast(string) cast(char[]) data;
    }


    bool read_bool()
    {
        bool value = true;
        if (read_ubyte() == 0)
            return false;
        return value;
    }

    void seek(int pos)
    {
        position = pos;
    }

    ushort bytes_available()
    {
        return cast(ushort)(this.buffer.length - position);
    }



    void write_ubyte(ubyte data)
    {
        buffer[position] = data;
        position++;
    }

    void write_byte(byte data)
    {
        buffer[position] = data;
        position++;
    }

    void write_bytes(in ubyte[] data)
    {
        for (int i = 0; i < data.length; i++)
        {
            buffer[position + i] = data[i];
        }
        position += data.length;
    }

    void write_float(float data)
    {
        uint fd = *cast(uint*)&data;
        ubyte[4] value = void;
        static if(LE)
            value = (cast(ubyte*)&fd)[0 .. 4];
        else
        {
            auto val = hton32(cast(uint*) &data);
            auto ptr = cast(ubyte*)&val;
            value = ptr[0 .. 4];
        }
        write_bytes(value);
    }

    void write_int(int data)
     {
        ubyte[4] value = void;
        static if(LE)
            value = (cast(ubyte*)&data)[0 .. 4];
        else
        {
            auto val = hton32(cast(uint*) &data);
            auto ptr = cast(ubyte*)&val;
            value = ptr[0 .. 4];
        }
        write_bytes(value);
    }

    void write_uint(uint data)
    {
        ubyte[4] value = void;
        static if(LE)
        {
            value = (cast(ubyte*)&data)[0 .. 4];
        }
        else
        {
            auto val = hton32(cast(uint*) &data);
            auto ptr = cast(ubyte*)&val;
            value = ptr[0 .. 4];
        }
        write_bytes(value);
    }

    void write_ulong(ulong data)
     {
        ubyte[8] value = void;
        static if(LE)
            value = (cast(ubyte*)&data)[0 .. 8];
        else
        {
            auto val = hton64(cast(ulong*) &data);
            auto ptr = cast(ubyte*)&val;
            value = ptr[0 .. 8];
        }
        write_bytes(value);
    }

    void write_short(short data)
     {
        ubyte[2] value = void;
        static if(LE)
            value = (cast(ubyte*)&data)[0 .. 2];
        else
        {
            auto val = hton16(cast(ushort*) &data);
            auto ptr = cast(ubyte*)&val;
            value = ptr[0 .. 2];
        }
        write_bytes(value);
    }

    void write_ushort(ushort data)
     {
        ubyte[2] value = void;
        static if(LE)
            value = (cast(ubyte*)&data)[0 .. 2];
        else
        {
            auto val = hton16(cast(ushort*) &data);
            auto ptr = cast(ubyte*)&val;
            value = ptr[0 .. 2];
        }
        write_bytes(value);
    }

    void write_double(double data)
    {
        ubyte[8] value = void;
        static if(LE)
            value = (cast(ubyte*)&data)[0 .. 8];
        else
        {
            auto val = hton64(cast(ulong*) &data);
            auto ptr = cast(ubyte*)&val;
            value = ptr[0 .. 8];
        }
        write_bytes(value);
    }

    void write_utf(in char[] data)
    {
        int size = cast(int)data.length;
        ubyte[] string = cast(ubyte[])data;
        write_int(size);
        if(size > 0)
            write_bytes(string);
    }

    void write_string(const(char)[] data)
    {
        short size = cast(short)data.length;
        ubyte[] string = cast(ubyte[])data;
        write_short(size);
        if(size > 0)
            write_bytes(string);
    }

    void write_string_null(in char[] data)
    {
        short size = 0;
        for(size = 0; size < data.length; size++)
        {
            if (data[size] == '\0') break;
        }
        write_short(size);
        if(size > 0)
            write_bytes(cast(ubyte[]) data[0 .. size]);
    }

    void write_cstring(char[] data)
    {
        auto l = 0;
        for(int i = 0; i < data.length; i++)
        {
            if(data[i] == 0) break;
            l++;
        }
        assert(l < short.max);

        write_short(cast(short) l);

        if(l > 0)
            write_bytes(cast(ubyte[]) data[0 .. l]);
    }

    void write_utf_bytes(in char[] data)
     {
        ubyte[] str = cast(ubyte[])data;
        write_bytes(str);
    }

    void write_bool(bool data)
    {
        if(data) write_ubyte(1);
        if(!data) write_ubyte(0);
    }
}

package:
// TODO: move to bitops module

pragma(inline, false)
ushort byteswap(ushort x) pure
{
    /* Calling it bswap(ushort) would break existing code that calls bswap(uint).
     *
     * This pattern is meant to be recognized by the dmd code generator.
     * Don't change it without checking that an XCH instruction is still
     * used to implement it.
     * Inlining may also throw it off.
     */
    return cast(ushort) (((x >> 8) & 0xFF) | ((x << 8) & 0xFF00u));
}


/// big endian to little
ulong ntoh64(ulong *input)
{
    ulong rval;
    ubyte *data = cast(ubyte*)&rval;

    data[0] =cast(ubyte)(*input >> 56);
    data[1] =cast(ubyte)(*input >> 48);
    data[2] =cast(ubyte)(*input >> 40);
    data[3] =cast(ubyte)(*input >> 32);
    data[4] =cast(ubyte)(*input >> 24);
    data[5] =cast(ubyte)(*input >> 16);
    data[6] =cast(ubyte)(*input >> 8);
    data[7] =cast(ubyte)(*input >> 0);

    return rval;
}

/// little endian to big
ulong hton64(ulong *input)
{
    return (ntoh64(input));
}

/// big endian to little
uint ntoh32(uint *input)
{
    uint rval;
    ubyte *data = cast(ubyte*)&rval;

    data[0] = cast(ubyte) (*input >> 24);
    data[1] = cast(ubyte) (*input >> 16);
    data[2] = cast(ubyte) (*input >> 8);
    data[3] = cast(ubyte) (*input >> 0);

    return rval;
}

/// little endian to big
uint hton32(uint *input)
{
    return (ntoh32(input));
}

/// big endian to little
ushort ntoh16(ushort *input)
{
    ushort rval;
    ubyte* data = cast(ubyte*) &rval;

    data[0] =cast(ubyte)(*input >> 8);
    data[1] =cast(ubyte)(*input >> 0);

    return rval;
}

/// little endian to big
ushort hton16(ushort *input)
{
    return (ntoh16(input));
}