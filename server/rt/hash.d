module rt.hash;

uint get_16(ubyte* a_data)
{
    return (cast(uint) a_data[0]) | ((cast(uint) a_data[1]) << 8);
}

uint hash_fast(ubyte[] a_data)
{
    ubyte* data = a_data.ptr;
    auto hash = cast(uint) a_data.length;
    auto left = cast(uint) a_data.length;

    if (left == 0)
    {
        return 0;
    }

    for (; left > 3; left -= 4)
    {
        uint value;
        hash += get_16(data);
        value = (get_16(data + 2) << 11);
        hash = (hash << 16) ^ hash ^ value;
        data += 4;
        hash += hash >> 11;
    }

    final switch (left)
    {
    case 3:
        hash += get_16(data);
        hash ^= hash << 16;
        hash ^= (cast(uint) data[2]) << 18;
        hash += hash >> 11;
        break;
    case 2:
        hash += get_16(data);
        hash ^= hash << 11;
        hash += hash >> 17;
        break;
    case 1:
        hash += cast(uint) data[0];
        hash ^= hash << 10;
        hash += hash >> 1;
        break;
    case 0:
        break;
    }

    hash ^= hash << 3;
    hash += hash >> 5;
    hash ^= hash << 4;
    hash += hash >> 17;
    hash ^= hash << 25;
    hash += hash >> 6;

    return hash;
}
