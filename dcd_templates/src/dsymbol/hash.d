/**
 * The content hash the module cache compares a source file against.
 *
 * This file is part of DCD, a development tool for the D programming language
 */
module dsymbol.hash;

import core.stdc.string : memcpy;

/**
 * XXH64 (https://xxhash.com/) - the 64-bit xxHash, 'seed' 0 by default.
 *
 * This replaced FNV-1a, whose byte-at-a-time mixing spreads near-identical
 * inputs poorly: the interesting input here is a source file next to its
 * previous revision, which is exactly that shape.  XXH64 also reads a word at
 * a time, and the cache hashes a whole module on every save.
 *
 * The vectors in the unittest below come from the reference implementation
 * ('xxh64sum' and python's 'xxhash').
 */
ulong xxh64(const(ubyte)[] data, ulong seed = 0)
{
    enum ulong prime1 = 0x9E3779B185EBCA87UL;
    enum ulong prime2 = 0xC2B2AE3D27D4EB4FUL;
    enum ulong prime3 = 0x165667B19E3779F9UL;
    enum ulong prime4 = 0x85EBCA77C2B2AE63UL;
    enum ulong prime5 = 0x27D4EB2F165667C5UL;

    static ulong round(ulong acc, ulong input)
    {
        return rotl64(acc + input * prime2, 31) * prime1;
    }

    static ulong mergeRound(ulong acc, ulong value)
    {
        acc ^= round(0, value);
        return acc * prime1 + prime4;
    }

    const(ubyte)* p = data.ptr;
    const(ubyte)* end = data.ptr + data.length;
    ulong h;

    if (data.length >= 32)
    {
        // Four accumulators, one block of 32 bytes per round.
        const(ubyte)* limit = end - 32;
        ulong v1 = seed + prime1 + prime2;
        ulong v2 = seed + prime2;
        ulong v3 = seed;
        ulong v4 = seed - prime1;

        do
        {
            v1 = round(v1, readLE64(p)); p += 8;
            v2 = round(v2, readLE64(p)); p += 8;
            v3 = round(v3, readLE64(p)); p += 8;
            v4 = round(v4, readLE64(p)); p += 8;
        }
        while (p <= limit);

        h = rotl64(v1, 1) + rotl64(v2, 7) + rotl64(v3, 12) + rotl64(v4, 18);
        h = mergeRound(h, v1);
        h = mergeRound(h, v2);
        h = mergeRound(h, v3);
        h = mergeRound(h, v4);
    }
    else
    {
        h = seed + prime5;
    }

    // The *total* length, not what is left: the tail below is what consumes
    // the remainder.
    h += data.length;

    while (p + 8 <= end)
    {
        h ^= round(0, readLE64(p));
        h = rotl64(h, 27) * prime1 + prime4;
        p += 8;
    }

    if (p + 4 <= end)
    {
        h ^= cast(ulong) readLE32(p) * prime1;
        h = rotl64(h, 23) * prime2 + prime3;
        p += 4;
    }

    while (p < end)
    {
        h ^= cast(ulong) *p * prime5;
        h = rotl64(h, 11) * prime1;
        p++;
    }

    // Avalanche.
    h ^= h >> 33;
    h *= prime2;
    h ^= h >> 29;
    h *= prime3;
    h ^= h >> 32;
    return h;
}

private ulong rotl64(ulong value, uint count)
{
    return (value << count) | (value >> (64 - count));
}

/// XXH64 is defined on little-endian input; the byte order of the machine
/// must not change the result.
private ulong readLE64(const(ubyte)* p)
{
    version (LittleEndian)
    {
        ulong value;
        memcpy(&value, p, ulong.sizeof);
        return value;
    }
    else
    {
        return cast(ulong) p[0]
            | cast(ulong) p[1] << 8
            | cast(ulong) p[2] << 16
            | cast(ulong) p[3] << 24
            | cast(ulong) p[4] << 32
            | cast(ulong) p[5] << 40
            | cast(ulong) p[6] << 48
            | cast(ulong) p[7] << 56;
    }
}

private uint readLE32(const(ubyte)* p)
{
    version (LittleEndian)
    {
        uint value;
        memcpy(&value, p, uint.sizeof);
        return value;
    }
    else
    {
        return cast(uint) p[0]
            | cast(uint) p[1] << 8
            | cast(uint) p[2] << 16
            | cast(uint) p[3] << 24;
    }
}

unittest
{
    // Vectors from the reference implementation: 'xxh64sum -H1' and
    // 'xxhash.xxh64(text, seed=0).intdigest()'.
    static immutable struct Vector
    {
        string text;
        ulong hash;
    }

    foreach (vector; cast(const Vector[]) [
        Vector("", 0xef46db3751d8e999UL),
        Vector("a", 0xd24ec4f1a98c6e5bUL),
        Vector("abc", 0x44bc2cf5ad770999UL),
        Vector("message digest", 0x066ed728fceeb3beUL),
        Vector("abcdefghijklmnopqrstuvwxyz", 0xcfe1f278fa89835cUL),
        // A real module, and the same module one member later: the shape this
        // hash is chosen for.
        Vector("module leaf;\n\nstruct Widget\n{\n    int size;\n}\n",
            0x220a3d9ddae97714UL),
        Vector("module leaf;\n\nstruct Widget\n{\n    int size;\n    int extra;\n}\n",
            0x1ccb22491fafc28eUL),
        // Length boundaries: 32 is where the main loop starts, 33 leaves a
        // single tail byte, 400 spans several blocks.
        Vector("xxxxxxx", 0x57abb58a45ee501aUL),
        Vector("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 0x60dd0d01083b99f0UL),
        Vector("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", 0xb3fa465f554208a6UL),
    ])
        assert(xxh64(cast(const(ubyte)[]) vector.text) == vector.hash);

    auto ascending32 = new ubyte[32];
    foreach (i; 0 .. ascending32.length)
        ascending32[i] = cast(ubyte)(i + 1);
    assert(xxh64(ascending32) == 0x89614b7813c0bd7fUL);

    auto ascending63 = new ubyte[63];
    foreach (i; 0 .. ascending63.length)
        ascending63[i] = cast(ubyte)(i + 1);
    assert(xxh64(ascending63) == 0xddb4f290c77f8618UL);

    auto zeros32 = new ubyte[32];
    assert(xxh64(zeros32) == 0xf6e9be5d70632cf5UL);

    auto many_a = new ubyte[400];
    many_a[] = 0x61;
    assert(xxh64(many_a) == 0xcde9e30a8eae6975UL);
}
