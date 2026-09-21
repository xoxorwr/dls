module rt.fmt;

// bece97ef248ad36d31a48fb761b4a41324c9c5d5

import rt.io.writer;
import rt.math;



alias isize = ptrdiff_t;
alias usize = size_t;


enum FAlign
{
    LEFT, CENTER, RIGHT
}

struct FormatOptions
{
    int precision = -1;
    int width = -1;
    FAlign alignment = FAlign.RIGHT;
    char fill = ' ';
}

void format(Char, Args...)(Writer writer, in Char[] fmt, Args args, size_t maxDepth = 1)
{
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

                    format_type(a, spec, FormatOptions(), writer, maxDepth);
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

        		writer.write( cast(ubyte[]) fmt[start .. end] );

            }
        }
    }
    // print remaining
    if(c < fmt.length)
    {
        writer.write( cast(ubyte[]) fmt[c .. fmt.length] );
    }
}

void format_type(T, Char, A...)(T value, scope Char[] fmt, ref FormatOptions options, Writer writer, size_t maxDepth)
{
    static if (is(T == enum))
        writer.write(cast(ubyte[]) enum_to_str(value));
    else static if (isBoolean!T)
        writer.write(cast(ubyte[]) (value ? "true": "false"));
    else static if (isSomeChar2!T)
	{
        ubyte[2] tmp = [ cast(ubyte) value, 0];
        writer.write(tmp);
        //format_int_value(value, fmt, options, writer);
    }
    else static if (isFloatingPoint!T)
        format_float_value(value, fmt, options, writer);
    else static if (isIntegral!T)
		format_int_value(value, fmt, options, writer);
    else static if (isSomeString!T)
    {
        //auto l = str_len(value.ptr);
        //if (l >= value.length)
        //    l = cast(int) value.length;
        writer.write(cast(ubyte[]) value);
    }
    else static if (is(T : const(char)*))
    {
        if (fmt == "ptr") // TODO: check if that's right
            format_int_value(cast(size_t) value, fmt, options, writer);
        else
        {
            if (value) {
                auto l = str_len(value);
        		writer.write(cast(ubyte[]) value[0 .. l]);
            } else {
           	 	writer.write(cast(ubyte[]) "<null>");
            }
        }
    }
    else static if (is(T : const(char)[]))
    {
        auto l = str_len(value);
        if (l >= value.length)
            l = cast(int) value.length;
        writer.write(cast(ubyte[]) value[0 .. l]);
    }
    else static if (isPointer!T)
    {
        if (!value)
            writer.write(cast(ubyte[]) "0x0");
        else
            format_int_value(cast(isize)value, "x", options, writer);
    }
    else static if (__traits(isStaticArray, T) || is(T == U[], U))
    {
        writer.write(cast(ubyte[]) "[");
        for (int i = 0; i < value.length; i++)
        {
            format_int_value(value[i], "x", options, writer);
            if (i < value.length - 1)
                writer.write(cast(ubyte[]) ", ");
        }
        writer.write(cast(ubyte[]) "]");
    }
    else
    {
        writer.write(cast(ubyte[]) "[?:");
        writer.write(cast(ubyte[]) T.stringof);
        writer.write(cast(ubyte[]) "]");
    }
}

void format_value(T, Char, A...)(T value, scope Char[] fmt, ref FormatOptions options, Writer writer)
{

}

void format_buff(Char, A...)(const(char)[] buf, ref FormatOptions options, Writer writer)
{

}

size_t format_int_value(T, Char)(T value, scope Char[] fmt, ref FormatOptions options, Writer writer)
{
    ubyte base = 10;
    bool lower = true;

    if (fmt.length > 0)
	{
    	if (fmt[0] == 'x')
        {
            base = 16;
            lower = true;
        }
        else if (fmt[0] == 'X')
        {
            base = 16;
            lower = false;
        }
	}


    // TODO: optimize buffer
    char[64] buffer = 0;
    size_t a = abs(value);
    size_t index = buffer.length;
    if (base == 10)
    {
        while(a >= 100)
        {
            index -= 2;
            auto slice = buffer[index .. $];
            auto d2 = digits2(a % 100);
            slice[0] = d2[0];
            slice[1] = d2[1];

            a /= 100;
        }

        if (a < 10)
        {
            index -= 1;
            buffer[index] = cast(char) ('0' + cast(char) a);
        }
        else
        {
            index -= 2;
            auto slice = buffer[index .. $];
            auto d2 = digits2(a % 100);
            slice[0] = d2[0];
            slice[1] = d2[1];
        }
    }
    else
    {
        while (true) {
            const digit = a % base;
            index -= 1;
            buffer[index] = digit_to_char(cast(ubyte) digit, lower);
            a /= base;
            if (a == 0) break;
        }
    }

    static if (__traits(isUnsigned, T) == false)
    {
        if (value < 0)
        {
            index -= 1;
            buffer[index] = '-';
        }
        else if (options.width == -1 || options.width == 0)
        {
            // positive, ignore +
        }
        else
        {
            index -=1;
            buffer[index] = '+';
        }
    }

    writer.write(cast(ubyte[]) buffer[index .. $]);
    return buffer.length - index;
}

void format_float_value(T, Char)(T value, scope Char[] fmt, ref FormatOptions options, Writer writer)
{
    enum FP_PRECISION = 6;
    enum INT_BUF_SIZE = 66;
    enum FLT_BUF_SIZE = INT_BUF_SIZE*2+1;

    if (fmt.length == 0 || fmt[0] == 'e')
    {
        double x = cast(double) value;

        //if (cast(ulong) x >> 63 == 1) // sign bit, 1 is negative
        //{
        //    writer.write(cast(ubyte[]) "-");
        //    x = -x;
        //}

        if (x == double.nan)
        {
            writer.write(cast(ubyte[]) "nan");
            return;
        }
        if (x == double.infinity)
        {
            writer.write(cast(ubyte[]) "inf");
            return;
        }

        //if (x == 0.0)
        //{
        //    writer.write(cast(ubyte[]) "0");
        //    if (options.precision > 0)
        //    {
        //    	writer.write(cast(ubyte[]) ".");
        //        for(int i=0; i < options.precision;i++)
        //        {
        //    		writer.write(cast(ubyte[]) "0");
        //        }
        //    }
        //    else
        //    {
        //    	writer.write(cast(ubyte[]) ".0");
        //    }
        //    writer.write(cast(ubyte[]) "e+00");
        //    return;
        //}

        char[66] buffer = 0;

        auto digits = fpconv_dtoa(value, buffer.ptr);
        writer.write(cast(ubyte[]) buffer[0 .. digits]);
    }
    else if (fmt[0] == 'd')
    {

    }
    else if (fmt[0] == 'x')
    {
        assert(0, "fuck off");
    }
}


string enum_to_str(E)(E v) if (is(E == enum))
{
    final switch (v) with(E)
    {
        static foreach (m; __traits(allMembers, E))
        {
    case mixin(m):
            return m;
        }
    }
}


package:

__gshared const(char)[] hex_table = "0123456789ABCDEF";

enum bool isSomeString(T) = is(immutable T == immutable C[], C) && (is(C == char) || is(C == wchar) || is(C == dchar));
enum bool isIntegral(T) = __traits(isIntegral, T);
enum bool isBoolean(T) = __traits(isUnsigned, T) && is(T : bool);
enum bool isSomeChar(T) = __traits(isUnsigned, T) && is(T : char);
enum bool isSomeChar2(T) = __traits(isUnsigned, T) && (is(T == char) || is(T == wchar) || is(T == dchar));
enum bool isFloatingPoint(T) = __traits(isFloating, T) && is(T : real);
enum bool isPointer(T) = is(T == U*, U) && __traits(isScalar, T);
enum bool isStaticArray(T) = __traits(isStaticArray, T);


char[2] digits2(size_t value) {
    __gshared str = "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899";
    auto slice = str[value * 2 .. $];

    return [ slice[0], slice[1] ];
}


char digit_to_char(ubyte value, bool lower)
{
    if (value >= 0 && value <= 9)
    	return cast(char) (value + '0');
    else if (value >= 10 && value <= 35)
        return cast(char) (value + ((lower ? 'a' : 'A') -  10));
    assert(0, "nope");
}

int str_len(const(char)[] txt)
{
    int l = 0;
    while(l != txt.length && txt[l] != '\0')
        l++;
    return l;
}

int str_len(const(char)* txt)
{
    if (!txt) return 0;

    int l = 0;
    while(txt[l] != '\0')
        l++;
    return l;
}

// grisu


enum npowers = 87;
enum steppowers = 8;
enum firstpower = -348; /* 10 ^ -348 */

enum expmax = -32;
enum expmin = -60;

enum expbits = 11; // 64 - 1 /*for signbit*/ - fracbits;
enum fracbits = 52;

enum fracmask = (1UL << fracbits) - 1;
enum hiddenbit =  (1UL << fracbits);
enum expmask = ((1UL << expbits) - 1) << fracbits;
enum signbit = (1UL << (double.sizeof * 8) -1); // 1 << (64 - 1)
enum expbias = (((1 << (expbits - 1)) -1) + fracbits);

static assert(fracbits + expbits + 1 == (double.sizeof * 8));


struct Fp {
    ulong frac;
    int exp;
};

enum seperate_arrays = 1;

static if (seperate_arrays)
{

    static immutable int[npowers] powers_ten_exps =
    [
        -1220, -1193, -1166, -1140,
        -1113, -1087, -1060, -1034,
        -1007, -980, -954, -927,
        -901, -874, -847, -821,
        -794, -768, -741, -715,
        -688, -661, -635, -608,
        -582, -555, -529, -502,
        -475, -449, -422, -396,
        -369, -343, -316, -289,
        -263, -236, -210, -183,
        -157, -130, -103, -77,
        -50, -24, 3, 30, 56,
        83, 109, 136, 162,
        189, 216, 242, 269,
        295, 322, 348, 375,
        402, 428, 455, 481,
        508, 534, 561, 588,
        614, 641, 667, 694,
        720, 747, 774, 800,
        827, 853, 880, 907,
        933, 960, 986, 1013,
        1039, 1066
    ];

    static immutable ulong[npowers] powers_ten_fracs =
    [
        18054884314459144840LU, 13451937075301367670LU, 10022474136428063862LU,
        14934650266808366570LU, 11127181549972568877LU, 16580792590934885855LU,
        12353653155963782858LU, 18408377700990114895LU, 13715310171984221708LU,
        10218702384817765436LU, 15227053142812498563LU, 11345038669416679861LU,
        16905424996341287883LU, 12595523146049147757LU, 9384396036005875287LU,
        13983839803942852151LU, 10418772551374772303LU, 15525180923007089351LU,
        11567161174868858868LU, 17236413322193710309LU, 12842128665889583758LU,
        9568131466127621947LU, 14257626930069360058LU, 10622759856335341974LU,
        15829145694278690180LU, 11793632577567316726LU, 17573882009934360870LU,
        13093562431584567480LU, 9755464219737475723LU, 14536774485912137811LU,
        10830740992659433045LU, 16139061738043178685LU, 12024538023802026127LU,
        17917957937422433684LU, 13349918974505688015LU, 9946464728195732843LU,
        14821387422376473014LU, 11042794154864902060LU, 16455045573212060422LU,
        12259964326927110867LU, 18268770466636286478LU, 13611294676837538539LU,
        10141204801825835212LU, 15111572745182864684LU, 11258999068426240000LU,
        16777216000000000000LU, 12500000000000000000LU, 9313225746154785156LU,
        13877787807814456755LU, 10339757656912845936LU, 15407439555097886824LU,
        11479437019748901445LU, 17105694144590052135LU, 12744735289059618216LU,
        9495567745759798747LU, 14149498560666738074LU, 10542197943230523224LU,
        15709099088952724970LU, 11704190886730495818LU, 17440603504673385349LU,
        12994262207056124023LU, 9681479787123295682LU, 14426529090290212157LU,
        10748601772107342003LU, 16016664761464807395LU, 11933345169920330789LU,
        17782069995880619868LU, 13248674568444952270LU, 9871031767461413346LU,
        14708983551653345445LU, 10959046745042015199LU, 16330252207878254650LU,
        12166986024289022870LU, 18130221999122236476LU, 13508068024458167312LU,
        10064294952495520794LU, 14996968138956309548LU, 11173611982879273257LU,
        16649979327439178909LU, 12405201291620119593LU, 9242595204427927429LU,
        13772540099066387757LU, 10261342003245940623LU, 15290591125556738113LU,
        11392378155556871081LU, 16975966327722178521LU, 12648080533535911531LU
    ];
}
else
{
    static immutable Fp[npowers] powers_ten = [
        { 18054884314459144840U, -1220 }, { 13451937075301367670U, -1193 },
        { 10022474136428063862U, -1166 }, { 14934650266808366570U, -1140 },
        { 11127181549972568877U, -1113 }, { 16580792590934885855U, -1087 },
        { 12353653155963782858U, -1060 }, { 18408377700990114895U, -1034 },
        { 13715310171984221708U, -1007 }, { 10218702384817765436U, -980 },
        { 15227053142812498563U, -954 }, { 11345038669416679861U, -927 },
        { 16905424996341287883U, -901 }, { 12595523146049147757U, -874 },
        { 9384396036005875287U, -847 }, { 13983839803942852151U, -821 },
        { 10418772551374772303U, -794 }, { 15525180923007089351U, -768 },
        { 11567161174868858868U, -741 }, { 17236413322193710309U, -715 },
        { 12842128665889583758U, -688 }, { 9568131466127621947U, -661 },
        { 14257626930069360058U, -635 }, { 10622759856335341974U, -608 },
        { 15829145694278690180U, -582 }, { 11793632577567316726U, -555 },
        { 17573882009934360870U, -529 }, { 13093562431584567480U, -502 },
        { 9755464219737475723U, -475 }, { 14536774485912137811U, -449 },
        { 10830740992659433045U, -422 }, { 16139061738043178685U, -396 },
        { 12024538023802026127U, -369 }, { 17917957937422433684U, -343 },
        { 13349918974505688015U, -316 }, { 9946464728195732843U, -289 },
        { 14821387422376473014U, -263 }, { 11042794154864902060U, -236 },
        { 16455045573212060422U, -210 }, { 12259964326927110867U, -183 },
        { 18268770466636286478U, -157 }, { 13611294676837538539U, -130 },
        { 10141204801825835212U, -103 }, { 15111572745182864684U, -77 },
        { 11258999068426240000U, -50 }, { 16777216000000000000U, -24 },
        { 12500000000000000000U, 3 }, { 9313225746154785156U, 30 },
        { 13877787807814456755U, 56 }, { 10339757656912845936U, 83 },
        { 15407439555097886824U, 109 }, { 11479437019748901445U, 136 },
        { 17105694144590052135U, 162 }, { 12744735289059618216U, 189 },
        { 9495567745759798747U, 216 }, { 14149498560666738074U, 242 },
        { 10542197943230523224U, 269 }, { 15709099088952724970U, 295 },
        { 11704190886730495818U, 322 }, { 17440603504673385349U, 348 },
        { 12994262207056124023U, 375 }, { 9681479787123295682U, 402 },
        { 14426529090290212157U, 428 }, { 10748601772107342003U, 455 },
        { 16016664761464807395U, 481 }, { 11933345169920330789U, 508 },
        { 17782069995880619868U, 534 }, { 13248674568444952270U, 561 },
        { 9871031767461413346U, 588 }, { 14708983551653345445U, 614 },
        { 10959046745042015199U, 641 }, { 16330252207878254650U, 667 },
        { 12166986024289022870U, 694 }, { 18130221999122236476U, 720 },
        { 13508068024458167312U, 747 }, { 10064294952495520794U, 774 },
        { 14996968138956309548U, 800 }, { 11173611982879273257U, 827 },
        { 16649979327439178909U, 853 }, { 12405201291620119593U, 880 },
        { 9242595204427927429U, 907 }, { 13772540099066387757U, 933 },
        { 10261342003245940623U, 960 }, { 15290591125556738113U, 986 },
        { 11392378155556871081U, 1013 }, { 16975966327722178521U, 1039 },
        { 12648080533535911531U, 1066 }
    ];
}


Fp find_cachedpow10(int exp, int* k)
{
    enum one_log_ten = 0.30102999566398114;

    int approx = cast(int) (-(exp + npowers) * one_log_ten);
    int idx = (approx - firstpower) / steppowers;

    while(1) {
        static if (seperate_arrays)
        {
            int current = exp + powers_ten_exps[idx] + 64;
        }
        else
        {
            int current = exp + powers_ten[idx].exp + 64;
        }

        if(current < expmin) {
            idx++;
            continue;
        }

        if(current > expmax) {
            idx--;
            continue;
        }

        *k = (firstpower + idx * steppowers);

        static if (seperate_arrays)
        {
            auto result = Fp(powers_ten_fracs[idx], powers_ten_exps[idx]);
        }
        else
        {
            auto result = powers_ten[idx];
        }

        return result;
    }
}

static immutable ulong[20] tens = [
    10000000000000000000U, 1000000000000000000U, 100000000000000000U,
    10000000000000000U, 1000000000000000U, 100000000000000U,
    10000000000000U, 1000000000000U, 100000000000U,
    10000000000U, 1000000000U, 100000000U,
    10000000U, 1000000U, 100000U,
    10000U, 1000U, 100U,
    10U, 1U
];

ulong get_dbits(double d)
{
    const bits = *cast(ulong*)&d;
    return bits;
}

Fp build_fp(double d)
{
    ulong bits = get_dbits(d);

    ulong frac = bits & fracmask;
    long lexp = (bits & expmask) >> fracbits;

    if(lexp) {
        frac += hiddenbit;
        lexp -= expbias;
    } else {
        lexp = -(expbias) + 1;
    }

    Fp fp = Fp (frac, cast(int)lexp);
    return fp;
}

double build_double(Fp fp)
{
  ulong bits;
  if (fp.exp == -(expbias) + 1)
  {
      bits = fp.frac;
  }
  else
  {
     bits = fp.frac - hiddenbit;
     bits |= ((ulong(fp.exp + expbias) << fracbits) & expmask);
  }

  double r = *(cast(double*) &bits);
  return r;
}

static assert (build_fp(double.max).build_double == double.max);

void normalize(Fp* fp)
{
    while ((fp.frac & hiddenbit) == 0) {
        fp.frac <<= 1;
        fp.exp--;
    }

    int shift = 64 - 52 - 1;
    fp.frac <<= shift;
    fp.exp -= shift;
}

void get_normalized_boundaries(Fp* fp, Fp* lower, Fp* upper)
{
    upper.frac = (fp.frac << 1) + 1;
    upper.exp = fp.exp - 1;

    while ((upper.frac & (hiddenbit << 1)) == 0) {
        upper.frac <<= 1;
        upper.exp--;
    }

    int u_shift = 64 - 52 - 2;

    upper.frac <<= u_shift;
    upper.exp = upper.exp - u_shift;


    int l_shift = fp.frac == 0x0010000000000000U ? 2 : 1;

    lower.frac = (fp.frac << l_shift) - 1;
    lower.exp = fp.exp - l_shift;


    lower.frac <<= lower.exp - upper.exp;
    lower.exp = upper.exp;
}

Fp multiply(const Fp* a, const Fp* b)
{
    enum lomask = 0x00000000FFFFFFFF;

    ulong ah_bl = (a.frac >> 32) * (b.frac & lomask);
    ulong al_bh = (a.frac & lomask) * (b.frac >> 32);
    ulong al_bl = (a.frac & lomask) * (b.frac & lomask);
    ulong ah_bh = (a.frac >> 32) * (b.frac >> 32);

    ulong tmp = (ah_bl & lomask) + (al_bh & lomask) + (al_bl >> 32);

    tmp += 1U << 31;

    ulong fract = ah_bh + (ah_bl >> 32) + (al_bh >> 32) + (tmp >> 32);
    int exp = a.exp + b.exp + 64;

    auto fp = Fp (fract, exp);

    return fp;
}

void round_digit(char* digits, int ndigits, ulong delta, ulong rem, ulong kappa, ulong frac)
{
    while (rem < frac && delta - rem >= kappa &&
           (rem + kappa < frac || frac - rem > rem + kappa - frac)) {

        --digits[ndigits - 1];
        rem += kappa;
    }
}

int generate_digits(const Fp* fp, const Fp* upper, const Fp* lower, char* digits, int* K)
{
    ulong wfrac = upper.frac - fp.frac;
    ulong delta = upper.frac - lower.frac;

    Fp one;
    one.frac = 1UL << -upper.exp;
    one.exp = upper.exp;

    ulong part1 = upper.frac >> -one.exp;
    ulong part2 = upper.frac & (one.frac - 1);

    int idx = 0, kappa = 10;

    for(auto div_idx = 10; kappa > 0; div_idx++) {

        ulong div = tens[div_idx];
        const digit = part1 / div;

        if (digit || idx) {
            digits[idx++] = cast(char) (digit + '0');
        }

        part1 -= digit * div;
        kappa--;

        ulong tmp = (part1 <<-one.exp) + part2;
        if (tmp <= delta) {
            *K += kappa;
            round_digit(digits, idx, delta, tmp, div << -one.exp, wfrac);

            return idx;
        }
    }


    auto unit_idx = 18;

    while(1) {
        part2 *= 10;
        delta *= 10;
        kappa--;

        const digit = part2 >> -one.exp;
        if (digit || idx) {
            digits[idx++] = cast(char) (digit + '0');
        }

        part2 &= one.frac - 1;
        if (part2 < delta) {
            *K += kappa;
            round_digit(digits, idx, delta, part2, one.frac, wfrac * tens[unit_idx]);

            return idx;
        }

        unit_idx--;
    }
}

static int grisu2(double d, char* digits, int* K)
{
    Fp w = build_fp(d);

    Fp lower, upper;
    get_normalized_boundaries(&w, &lower, &upper);

    normalize(&w);

    int k;
    Fp cp = find_cachedpow10(upper.exp, &k);

    w = multiply(&w, &cp);
    upper = multiply(&upper, &cp);
    lower = multiply(&lower, &cp);

    lower.frac++;
    upper.frac--;

    *K = -k;

    return generate_digits(&w, &upper, &lower, digits, K);
}

static int emit_digits(char* digits, int ndigits, char* dest, int K, bool neg)
{
    int exp = ((K + ndigits - 1) < 0 ? -(K + ndigits - 1) : (K + ndigits - 1));


    if(K >= 0 && (exp < (ndigits + 7))) {
        dest[0 .. ndigits] = digits[0 .. ndigits];
        //memcpy(dest, digits, ndigits);
        dest[ndigits .. ndigits + K] =  '0';
        //memset(dest + ndigits, '0', K);

        return ndigits + K;
    }


    if(K < 0 && (K > -7 || exp < 4)) {
        int offset = ndigits - ((K) < 0 ? -(K) : (K));

        if(offset <= 0) {
            offset = -offset;
            dest[0] = '0';
            dest[1] = '.';

            //memset(dest + 2, '0', offset);
            dest[2 .. 2 + offset] = '0';
            //memcpy(dest + offset + 2, digits, ndigits);
            dest[2 + offset .. 2 + offset + ndigits] = digits[0 .. ndigits];

            return ndigits + 2 + offset;


        } else {
            //memcpy(dest, digits, offset);
            dest[0 .. offset] = digits[0 .. offset];
            dest[offset] = '.';
            //memcpy(dest + offset + 1, digits + offset, ndigits - offset);
            dest[offset + 1 .. 1 + ndigits] = digits[offset .. ndigits];

            return ndigits + 1;
        }
    }


    ndigits = ((ndigits) < (18 - neg) ? (ndigits) : (18 - neg));

    int idx = 0;
    dest[idx++] = digits[0];

    if(ndigits > 1) {
        dest[idx++] = '.';
        //memcpy(dest + idx, digits + 1, ndigits - 1);
        dest[idx .. idx + ndigits - 1] = digits[1 .. ndigits];
        idx += ndigits - 1;
    }

    dest[idx++] = 'e';

    char sign = K + ndigits - 1 < 0 ? '-' : '+';
    dest[idx++] = sign;

    auto _cent = 0;

    if(exp > 99) {
        _cent = exp / 100;
        dest[idx++] = cast(char) (_cent + '0');
        exp -= _cent * 100;
    }
    if(exp > 9) {
        int dec = exp / 10;
        dest[idx++] = cast(char) (dec + '0');
        exp -= dec * 10;

    } else if(_cent) {
        dest[idx++] = '0';
    }

    dest[idx++] = exp % 10 + '0';

    return idx;
}
/+
static int filter_special(double fp, char* dest)
{
    ulong bits = get_dbits(fp);

    if((bits & ~signbit) == 0) {
        dest[0] = '0';
        return 1;
    }


    bool nan = (bits & expmask) == expmask;

    if(!nan) {
        return 0;
    }

    if(bits & fracmask) {
        dest[0] = 'n'; dest[1] = 'a'; dest[2] = 'n';

    } else {
        dest[0] = 'i'; dest[1] = 'n'; dest[2] = 'f';
    }

    return 3;
}
+/
int fpconv_dtoa(double d, /*ref char[24]*/ char* dest)
{
    char[18] digits;
    int str_len = 0;
    bool neg = 0;
    ulong bits = (*(cast(ulong*)&d));


    if(bits & signbit) {
        dest[0] = '-';
        str_len = 1;
        neg = 1;
    }

    if ((bits & ~signbit) == 0)
    {
       dest[str_len] = '0';
       return ++str_len;
    }

   // manually inlined is_special

    bool is_nan = ((bits & expmask) == expmask);

    if (is_nan)
    {
        // this case is unlikely
        // add branch hint when avilable
        {
            str_len = 3;
            if (bits & 0x000FFFFFFFFFFFFFU)
            {
                dest[0 .. 3] = "nan";
            }
            else
            {
                if (neg)
                {
                    dest[1 .. 4] = "inf";
                    str_len = 4;
                }
                else
                {
                    dest[0 .. 3] = "inf";
                }
            }
        }

        return str_len;
    }

    int K = 0;
    auto ndigits = grisu2(d, &digits[0], &K);

    str_len += emit_digits(&digits[0], ndigits, &dest[str_len], K, neg);
    return str_len;
}

