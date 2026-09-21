module rt.io.writer;

struct Writer
{
    struct VT
    {
		size_t function(void* ptr, scope ubyte[] data) write;
    }
    void* ptr;
    VT vt;


    size_t write(scope ubyte[] data)
    {
        return vt.write(ptr, data);
    }
}

