module rt.io.reader;

struct Reader
{
    struct VT
    {
		size_t function(void* ptr, ubyte[] dest) read;
    }
    void* ptr;
    VT vt;
}
