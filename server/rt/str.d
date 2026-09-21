module rt.str;

import rt.memz;
import rt.dbg;

version (WebAssembly)
{

}
else
{
    import core.stdc.string;
}


//bool equals(inout(char)* lhs, const(char)[] rhs)
//{
//    auto lhsLen = str_len(lhs);
//    return equals(lhs[0..lhsLen], rhs);
//}

bool isupper(int c)
{
	return cast(char)c-'A' < 26;
}

int str_len(const(char)* txt)
{
    if (!txt) return 0;

    int l = 0;
    while(txt[l] != '\0')
        l++;
    return l;
}

int str_len(const(char)[] txt)
{
    int l = 0;
    while(l != txt.length && txt[l] != '\0')
        l++;
    return l;
}

bool str_ends_with(const(char)* S, const(char)* E)
{
    return (strcmp(S + str_len(S) - ((E).sizeof-1), E) == 0);
}


extern(C) int strcmp(const(char)* l, const(char)* r)
{
    for (; *l==*r && *l; l++, r++){}
    return *cast(ubyte*)l - *cast(ubyte*)r;
}

void strcpy(char *dst, const char *src)
{
    assert(dst);
    assert(src);

    auto l = str_len(src) + 1;
    memcpy(cast(void*)dst, cast(const(void)*)src, l);
}


size_t int_to_str(int value, char *sp, int radix = 10)
{
    char[32] tmp;// be careful with the length of the buffer
    char *tp = tmp.ptr;
    int i;
    uint v;

    int sign = (radix == 10 && value < 0);
    if (sign)
        v = -value;
    else
        v = cast(uint)value;

    while (v || tp == tmp.ptr)
    {
        i = v % radix;
        v /= radix;
        if (i < 10)
          *tp++ = cast(char)(i+'0');
        else
          *tp++ = cast(char)( i + 'a' - 10);
    }

    size_t len = tp - tmp.ptr;

    if (sign)
    {
        *sp++ = '-';
        len++;
    }

    while (tp > tmp.ptr)
        *sp++ = *--tp;

    return len;
}

char* float_to_str(char* outstr, float value, int decimals, int minwidth = 0, bool rightjustify = false)
{
    // this is used to write a float value to string, outstr.  oustr is also the return value.
    int digit;
    float tens = 0.1;
    int tenscount = 0;
    int i;
    float tempfloat = value;
    int c = 0;
    int charcount = 1;
    int extra = 0;
    // make sure we round properly. this could use pow from <math.h>, but doesn't seem worth the import
    // if this rounding step isn't here, the value  54.321 prints as 54.3209

    // calculate rounding term d:   0.5/pow(10,decimals)
    float d = 0.5;
    if (value < 0)
        d *= -1.0;
    // divide by ten for each decimal place
    for (i = 0; i < decimals; i++)
        d/= 10.0;
    // this small addition, combined with truncation will round our values properly
    tempfloat +=  d;

    // first get value tens to be the large power of ten less than value
    if (value < 0)
        tempfloat *= -1.0;
    while ((tens * 10.0) <= tempfloat) {
        tens *= 10.0;
        tenscount += 1;
    }

    if (tenscount > 0)
        charcount += tenscount;
    else
        charcount += 1;

    if (value < 0)
        charcount += 1;
    charcount += 1 + decimals;

    minwidth += 1; // both count the null final character
    if (minwidth > charcount){
        extra = minwidth - charcount;
        charcount = minwidth;
    }

    if (extra > 0 && rightjustify) {
        for (int j = 0; j< extra; j++) {
            outstr[c++] = ' ';
        }
    }

    // write out the negative if needed
    if (value < 0)
        outstr[c++] = '-';

    if (tenscount == 0)
        outstr[c++] = '0';

    for (i=0; i< tenscount; i++) {
        digit = cast(int) (tempfloat/tens);
        int_to_str(digit, &outstr[c++], 10);
        tempfloat = tempfloat - (cast(float)digit * tens);
        tens /= 10.0;
    }

    // if no decimals after decimal, stop now and return

    // otherwise, write the point and continue on
    if (decimals > 0)
    outstr[c++] = '.';


    // now write out each decimal place by shifting digits one by one into the ones place and writing the truncated value
    for (i = 0; i < decimals; i++) {
        tempfloat *= 10.0;
        digit = cast(int) tempfloat;
        int_to_str(digit, &outstr[c++], 10);
        // once written, subtract off that digit
        tempfloat = tempfloat - cast(float) digit;
    }
    if (extra > 0 && !rightjustify) {
        for (int j = 0; j< extra; j++) {
            outstr[c++] = ' ';
        }
    }


    outstr[c++] = '\0';
    return outstr;
}

float string_to_float(const(char)* str)
{
    int len = 0, n = 0, i = 0;
    float f = 1.0, val = 0.0;
    bool neg = false;
    if (str[0] == '-')
    {
        i = 1;
        neg = true;
    }

    while (str[len])
        len++;

    if (!len)
        return 0;

    while (i < len && str[i] != '.')
        n = 10 * n + (str[i++] - '0');

    if (i == len)
        return n;
    i++;
    while (i < len)
    {
        f *= 0.1;
        val += f * (str[i++] - '0');
    }
    float ret = (val + n);
    if (neg)
        ret = -ret;
    return ret;
}

char[] concat_str(char[] a, char[] b)
{
    auto end = str_len(a.ptr);
    for (size_t i = 0; i < b.length; i++)
    {
        if (end + i >= a.length) break;
        a[end + i] = b[i];
    }
    return a;
}

bool contains(const(char)[] str, const(char)[] value)
{
    auto str_l = str_len(str);
    auto value_l = str_len(value);

    if (str_l == 0) return false;
    if (value_l == 0) return false;
    if (str_l < value_l) return false;

    int a;
    int b;
    while (a < str_l)
    {
        if (str[a] == value[b])
        {
            b++;
            if (b == value_l)
                return true;
        }
        a++;
    }
    return false;
}

unittest
{
    char[32] a = "hello";
    char[32] b = "world";
    char[32] c = "test that";

    //assert(contains(a, "hello"));
    //assert(contains(b, "world"));

    //assert(starts_with(a, "he"));
    //assert(ends_with(a, "lo"));

    //assert(index_of(a, "h") == 0);
    //assert(index_of(a, "o") == 4);
    //assert(index_of(a, "l") == 2);
    //assert(index_of(c, " ") == 4);
}

static int count_digits(int value)
{
    int count = 0;
    do
    {
        value /= 10;
        ++count;
    }
    while (value != 0);
    return count;
}

int isspace(int c)
{
    //return c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r' || c == ' ';
    return c == ' ' || cast(int) c-'\t' < 5;
}


int isxdigit(int c)
{
    return isdigit(c) || (cast(uint)c|32)-'a' < 6;
}

int isdigit(int c)
{
    return (c >= '0' && c <= '9');
}

int _digit_value(char r) {
    int ri = cast(int)(r);
    int v = 16;
    if (r >= '0' && r <= '9') v = ri-'0';
    else if (r >= 'a' && r <= 'z') v = ri-'a'+10;
    else if (r >= 'A' && r <= 'Z') v = ri-'A'+10;
    return v;
}

long atoll(const char * str)
{
    char* s = cast(char*) str;
    long n=0;
    int neg=0;
    while (isspace(*s)) s++;
    switch (*s) {
    case '-': neg=1; s++; break;
    case '+': s++;break;
    default: break;
    }
    /* Compute n as a negative number to avoid overflow on LLONG_MIN */
    while (isdigit(*s))
        n = 10*n - (*s++ - '0');
    return neg ? n : -n;
}

int str_to_int(const (char)* str, size_t len)
{
    int i;
    int ret = 0;
    for(i = 0; i < len; ++i)
    {
        ret = ret * 10 + (str[i] - '0');
    }
    return ret;
}

int str_to_int(const(char)[] str)
{
    int i;
    int ret = 0;
    for(i = 0; i < str.length; ++i)
    {
        ret = ret * 10 + (str[i] - '0');
    }
    return ret;
}

int hex_to_int(const(char)[] str)
{
    uint val = 0;
    for (int i = 0; i < str.length; i++)
    {
        char b = str[i];
        // transform hex character to the 4bit equivalent number, using the ascii table indexes
        if (b >= '0' && b <= '9')     b = cast(char)( b - '0');
        else if (b >= 'a' && b <='f') b = cast(char)( b - 'a' + 10);
        else if (b >= 'A' && b <='F') b = cast(char)( b - 'A' + 10);
        // shift 4 to make space for new digit, and add the 4 bits of the new digit
        val = (val << 4) | (b & 0xF);
    }
    // char* hex = cast(char*)str.ptr;
    // uint val = 0;
    // while (*hex) {
    //     // get current character then increment
    //     char b = *hex++;
    //     // transform hex character to the 4bit equivalent number, using the ascii table indexes
    //     if (b >= '0' && b <= '9')     b = cast(char)( b - '0');
    //     else if (b >= 'a' && b <='f') b = cast(char)( b - 'a' + 10);
    //     else if (b >= 'A' && b <='F') b = cast(char)( b - 'A' + 10);
    //     // shift 4 to make space for new digit, and add the 4 bits of the new digit
    //     val = (val << 4) | (b & 0xF);
    // }
    return val;
}

const(char)[] strip(const(char)[] p)
{
    assert(p);
    int l = str_len(p.ptr);
    if (l >= p.length)
        l = cast(int) p.length;

    return p[0 .. l];
}

const(char)[] strip_ptr(const(char*) p)
{
    assert(p);
    int l = str_len(p);
    return p[0 .. l];
}

int parse_i32(const(char)[] str) {
    return cast(int) parse_i64(str);
}

long parse_i64(const(char)[] str) {
    auto s = str;
    auto neg = false;
    if (s.length > 1)
    {
        switch (s[0])
        {
        case '-':
            neg = true;
            s = s[1 .. $];
            break;
        case '+':
            s = s[1 .. $];
            break;
        default:
            break;
        }
    }

    long value = 0;
    long base = 10;
    if (s.length > 2 && s[0] == '0') {
        switch (s[1]) {
            case 'b': base =  2;  s = s[2 .. $]; break;
            case 'o': base =  8;  s = s[2 .. $]; break;
            case 'd': base = 10;  s = s[2 .. $]; break;
            case 'z': base = 12;  s = s[2 .. $]; break;
            case 'x': base = 16;  s = s[2 .. $]; break;
            default: break;
        }
    }


    //foreach (r;s) {
    //  if (r == '_') {
    //      continue;
    //  }

    //  long v = _digit_value(r);
    //  if (v >= base) {
    //      break;
    //  }
    //  value *= base;
    //  value += v;
    //}

    //if (str == "0xC6136")
    //{
    //    LINFO("{} {}", s, value);
    //}
    long i = 0;
    foreach (r; s) {
        if (r == '_') {
            i += 1;
            continue;
        }
        auto v = cast(long)(_digit_value(r));
        if (v >= base) {
            break;
        }
        value *= base;
        value += v;
        i += 1;
    }
    s = s[cast(int)i..$];

    if (neg) return -value;

    //if (str == "0xC6136")
    //{
    //    LINFO("{} {}", value, cast(ushort) value);
    //}
    return value;
}

ulong parse_u64(const(char)[] str) {
    auto s = str;
    auto neg = false;
    if ((s.length) > 1 && s[0] == '+') {
        s = s[1 .. $];
    }

    ulong base = 10;
    if ((s.length) > 2 && s[0] == '0') {
        switch (s[1]) {
            case 'b': base =  2;  s = s[2 .. $]; break;
            case 'o': base =  8;  s = s[2 .. $]; break;
            case 'd': base = 10;  s = s[2 .. $]; break;
            case 'z': base = 12;  s = s[2 .. $]; break;
            case 'x': base = 16;  s = s[2 .. $]; break;
            default: break;
        }
    }


    ulong value;
    foreach (r; s) {
        if (r == '_') continue;
        ulong v = cast(ulong)(_digit_value(r));
        if( v >= base) break;
        value *= base;
        value += cast(ulong)(v);
    }

    if (neg) return -value;
    return value;
}

float parse_f32(const(char)[] str)
{
    return cast(float) parse_f64(str);
}

double parse_f64(const(char)[] str)
{
    if (str == null) {
        return 0;
    }
    size_t i = 0;

    double sign = 1;
    switch (str[i]) {
        case '-': {i += 1; sign = -1;break;}
        case '+': {i += 1;break;}
        default: break;
    }

    double value = 0;
    for (; i < str.length; i += 1) {
        auto r = str[i];
        if (r == '_') continue;

        auto v = _digit_value(r);
        if (v >= 10) break;
        value *= 10;
        value += cast(double)(v);
    }

    if (i < str.length && str[i] == '.') {
        double pow10 = 10;
        i += 1;

        for (; i < str.length; i += 1) {
            auto r = str[i];
            if (r == '_') continue;

            auto v = _digit_value(r);
            if (v >= 10) break;
            value += cast(double)v/pow10;
            pow10 *= 10;
        }
    }

    bool frac = false;
    double scale = 1;

    if (i < str.length && (str[i] == 'e' || str[i] == 'E')) {
        i += 1;

        if (i < str.length) {
            switch (str[i]) {
            case '-': {i += 1; frac = true; break;}
            case '+': {i += 1;break;}
            default: break;
            }

            uint exp = 0;
            for (; i < str.length; i += 1) {
                auto r = str[i];
                if (r == '_') continue;

                auto d = cast(uint)(_digit_value(r));
                if (d >= 10) break;
                exp = exp * 10 + d;
            }
            if (exp > 308) { exp = 308; }

            while (exp >= 50) { scale *= 1e50; exp -= 50; }
            while (exp >=  8) { scale *=  1e8; exp -=  8; }
            while (exp >   0) { scale *=   10; exp -=  1; }
        }
    }

    if (frac) return sign * (value/scale);

    return sign * (value*scale);
}


struct StringBuilder
{
    char[] buffer;
    size_t pos;

    void set(char[] buffer)
    {
        this.buffer = buffer;
        pos = 0;
    }

    void append_char(char value)
    {
        if (pos + 1 >  buffer.length) panic("nope");
        buffer[pos] = value;
        pos += 1;
    }
    void append_int(int value)
    {
        auto c = count_digits(value);
        if (value < 0) c++;

        if (pos + c >  buffer.length) panic("nope");
        int_to_str(value, &buffer[pos]);
        pos += c;
    }

    void append_float(float value, int decimals)
    {
        auto c = count_digits(cast(int)value) + 1 + decimals;
        if (value < 0) c++;

        if (pos + c >  buffer.length) panic("nope");
        float_to_str(&buffer[pos], value, decimals);
        pos += c;
    }

    void append_string(const (char)[] str)
    {
        assert(pos + str.length < buffer.length);

        memcpy(&buffer[pos], str.ptr, str.length);
        pos += str.length;
    }
    void append_line(const (char)[] str)
    {
        assert(pos + str.length < buffer.length);

        memcpy(&buffer[pos], str.ptr, str.length);
        pos += str.length;

        append_char('\n');
    }

    void append_line(T...)(T args)
    {
        append(args);
        append_char('\n');
    }
    void append(T...)(T args)
    {
        foreach(a; args)
        {
            alias A = typeof(a);

            static if ( is(A == string))
            {
                append_string(a);
            }
            else static if ( is(A : const(char)[]))
            {
                append_string(a);
            }
            else static if ( is(A : char[]))
            {
                append_string(a);
            }
            else static if ( is(A == char*) || is(A == const(char)*))
            {
                auto len = str_len(a);
                append_string(a[0 .. len]);
            }
            else static if( is( A == float) )
            {
                append_float(a, 2);
            }
            else static if( is( A == double) )
            {
                append_float(cast(float)a, 2);
            }
            else static if( is( A == ulong) )
            {
                append_int(cast(int)a);
            }
            else static if( is( A == long) )
            {
                append_int(cast(int)a);
            }
            else static if( is( A == int) )
            {
                append_int(a);
            }
            else static if( is( A == uint) || is(A == const(uint)) )
            {
                append_int(a);
            }
            else static if( is( A == ushort) )
            {
                append_int(a);
            }
            else static if( is( A == ubyte) )
            {
                append_int(a);
            }
            else static if( is( A == char) )
            {
                append_char(a);
            }
            else
            {
                pragma(msg, A);
                static assert(0, A.stringof);
            }
        }
    }

    char[] slice()
    {
        // assert(pos > 0);
        buffer[pos] = '\0';
        return buffer[0 .. pos];
    }
}


void writef(Char, A...)(inout(char)[] buffer, in Char[] fmt, scope A args)
{
    // TODO: finish this shit
    // TODO: have a Writer interface, so it's reausable with dbg module

    int bcur = 0;

    enum bool isSomeString(T) = is(immutable T == immutable C[], C) && (is(C == char) || is(C == wchar) || is(C == dchar));
    enum bool isIntegral(T) = __traits(isIntegral, T);
    enum bool isBoolean(T) = __traits(isUnsigned, T) && is(T : bool);
    enum bool isSomeChar(T) = __traits(isUnsigned, T) && is(T : char);
    enum bool isSomeChar2(T) = __traits(isUnsigned, T) && (is(T == char) || is(T == wchar) || is(T == dchar));
    enum bool isFloatingPoint(T) = __traits(isFloating, T) && is(T : real);
    enum bool isPointer(T) = is(T == U*, U) && __traits(isScalar, T);
    enum bool isStaticArray(T) = __traits(isStaticArray, T);

    static assert(isSomeString!(typeof(fmt)));

    bool inside = false;
    size_t c;
    size_t spec_start;
    size_t spec_end;
    foreach (a; args)
    {
        alias T = typeof(a);

        foreach (i, f; fmt)
        {
            if (i < c)
                continue;

            if (f == '{')
            {
                inside = true;
                spec_start = i + 1;
            }
            else if (f == '}')
            {
                if (inside)
                {
                    scope (exit) spec_start = spec_end = 0;

                    spec_end = i;
                    auto hasSpec = spec_end != spec_start;
                    auto spec = fmt[spec_start .. spec_end];

                    static if (is(T == enum))
                    {
                        //print_str(enum_to_str(a).ptr);
                    }
                    else static if (isBoolean!T)
                	{
                        //print_str(a ? "true": "false");
                    }
                    else static if (isSomeChar2!T)
                    {
                        //print_char(a);
                    }
                    else static if (isFloatingPoint!T)
                    {
                    	//print_float(a);
                    }
                    else static if (isIntegral!T)
                    {
                        //static if (is(T : int))
                        //{
                        //    static if (__traits(isUnsigned, T))
                        //           print_uint(a);
                        //    else
                        //        print_int(a);
                        //}
                        //else static if (is(T : long))
                        //{
                        //    static if (__traits(isUnsigned, T))
                        //           print_ulong(a);
                        //    else
                        //        print_long(a);
                        //}
                    }
                    else static if (isSomeString!T)
                    {
                        auto l = str_len(a.ptr);
                        if (l >= a.length)
                            l = cast(int) a.length;
        				memcpy(&buffer[bcur], a.ptr, l);
                        bcur += l;
                    }
                    else static if (is(T : const(char)*))
                    {
                        //if (spec == "ptr")
                        //    print_long(cast(size_t) a);
                        //else
                        {
                            if (a) {
                                auto l = str_len(a);
                                print_str_len(a, l);
                				memcpy(&buffer[bcur], a.ptr, l);
                                bcur += l;
                            } else {
                                //print_str("<null>");
                            }
                        }
                    }
                    else static if (is(T : const(char)[]))
                    {
                        auto l = str_len(a.ptr);
                        if (l >= a.length)
                            l = cast(int) a.length;
        				memcpy(&buffer[bcur], a.ptr, l);
                        bcur += l;
                    }
                    else static if (isPointer!T)
                    {
                        //if (!a)
                        //    print_str("0x0");
                        //else
                        //    print_ptr(a);
                    }
                    else
                    {
                        //alias TN = T.stringof;
                        //print_str("[?:");
                        //print_str(T.stringof);
                        //print_str("]");
                    }
                }
                inside = false;
                c = i + 1;
                break;
            }
            else if (!inside)
            {
                size_t start = i;
                size_t end = i;
                for(size_t j = start; j < fmt.length; j++)
                {
                    if(fmt[j] == '{')
                    {
                        break;
                    }
                    end++;
                }

                c = end;

                // printf("%.*s", end - start, fmt[start .. end].ptr);
        		memcpy(&buffer[bcur], &fmt[start], end - start);
                bcur += (end - start);
            }
        }
    }
    // print remaining
    if(c < fmt.length)
    {
        //printf("%.*s", cast(int) (fmt.length - c), fmt[c .. $].ptr);
        memcpy(&buffer[bcur], &fmt[c], cast(int) (fmt.length - c));
        bcur += (fmt.length - c);
    }
}



struct SplitIterator(T)
{
    const(T)[] buffer;
    const(T)[] delimiter;
    SplitOption option;
    int index = 0;

    int count()
    {
        int c = 0;
        foreach(i, line; this)
        {
            c++;
        }
        index = 0;
        return c;
    }

    const(T) get(int index)
    {
        return buffer[index];
    }

    int opApply(scope int delegate(int, const(T)[]) dg)
    {
        auto length = buffer.length;
        for (int i = 0; i < length; i++)
        {
            if (buffer[i] == '\0')
            {
                length = i;
                break;
            }
        }

        int n = 0;
        int result = 0;
        for (int i = index; i < length; i++)
        {
            int entry(int start, int end)
            {
                if (start == end) return 0;

                // trim only if we got something
                if ((end - start > 0) && (option & SplitOption.TRIM))
                {
                    for (int j = start; j < end; j++)
                        if (buffer[j] == ' ')
                            start += 1;
                        else
                            break;
                    for (int k = end; k >= start; k--)
                        if (buffer[k - 1] == ' ')
                            end -= 1;
                        else
                            break;

                    // nothing left
                    if(start >= end) return 0;
                }

                //printf("%i to %i :: %i :: total: %lu\n", start, end, index, buffer.length);
                return dg(n++, buffer[start .. end]) != 0;
            }

            // TODO: FIXME: Assertion `array slice out of bounds' failed.
            //   foreach(i, it; split(cast(char[])"buf\nfer", "\r\n", SplitOption.TRIM))
            auto c = buffer[i .. i + delimiter.length];
            if (c == delimiter)
            {
                if (i == index && (option & SplitOption.REMOVE_EMPTY))
                {
                    // skip if we keep finding the delimiter
                    index = i + 1;
                    continue;
                }

                if ((result = entry(index, i)) != 0)
                    break;

                // skip delimiter for next result
                index = i + 1;
            }

            // handle what's left
            if ((i + 1) == length)
            {
                result = entry(index, i + 1);
            }
        }
        return result;
    }
}

version(Windows)
enum NL = "\n\t";
else
enum NL = "\n";

enum SplitOption
{
    NONE = 0,
    REMOVE_EMPTY = 1,
    TRIM = 2
}

SplitIterator!T split(T)(const(T)[] buffer, const(T)[] delimiter, SplitOption option = SplitOption.NONE)
{
    return SplitIterator!T(buffer, delimiter, option);
}

T[][] split_alloc(T)(Allocator allocator, const(T)[] text, const(T)[] delimiter, SplitOption option = SplitOption.NONE)
{
    auto iterator = split(text, delimiter, option);
    auto count = iterator.count();
    if(count == 0) return T[][].init;

    auto result = allocator.alloc!(T[])(count);
    foreach(i, line; iterator)
    {
        result[i] = cast(T[]) line;
    }
    return result;
}

int split(T)(T[][] buffer, const(T)[] text, const(T)[] delimiter, SplitOption option = SplitOption.NONE)
{
    auto iterator = split(text, delimiter, option);
    auto count = iterator.count();
    if(count == 0) return 0;
    auto c = 0;
    foreach(i, line; iterator)
    {
        if(i == buffer.length) break;
        buffer[i] = cast(T[]) line;
        c++;
    }
    return c;
}



char[N] formatN(int N)()
{
    char[N] ret;
    return ret;
}



struct str(bool STATIC, size_t N = 0)
{
    static if (STATIC)
        char[N] buffer;
    else
        char[] buffer;
    size_t len = 0;

    static if (STATIC)
        Allocator allocator;

    void create(Allocator allocator)
    {
        static if (STATIC)
        {
            this.allocator = allocator;
            buffer = allocator.alloc!(char)(128);
        }
        buffer[0] = 0;
    }

    const(char)[] slice()
    {
        return buffer[0 .. len];
    }
}


bool is_alpha_num(char c)
{
    auto hc = c | 0x20;
    return ('0' <= c && c <= '9') || ('a' <= hc && hc <= 'z');
}