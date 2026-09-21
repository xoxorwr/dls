module rt.filesystem;

import rt.dbg;
import rt.sync;
import rt.time;
import rt.str;
import mem = rt.memz;
import rt.container;

version (WebAssembly)
{
    import rt.wasm;
}
else
{
    version = HAS_THREADS;
}

version (Windows)
{
    import core.sys.windows.windef : HANDLE, LPDWORD, DWORD,
        SECURITY_ATTRIBUTES, GENERIC_READ, FILE_SHARE_READ, FILE_ATTRIBUTE_NORMAL,
        GENERIC_WRITE;
    import core.sys.windows.winbase : OPEN_EXISTING, INVALID_HANDLE_VALUE,
        CREATE_ALWAYS,
        GetFileSize, CreateFileA, CloseHandle, WriteFile, FlushFileBuffers,
        ReadFile;
}
else version (Posix)
{
    import core.stdc.stdio : fopen, ftell, fseek, fread, fclose, fwrite, fflush, FILE, SEEK_SET, SEEK_END;
}



char[256] make_path(T...)(T args)
{
    char[256] ret = 0;
    int cursor = 0;

    version(Windows)
    char sep = '\\';
    else
    char sep = '/';

    enum argslen = args.length;
    foreach(i, a; args)
    {
        auto slen = str_len(a.ptr);
        mem.memcpy(&ret[cursor], a.ptr, slen);
        cursor += slen;
        if (i < argslen-1 && a[slen-1] != sep)
        {
            ret[cursor++] = sep;
        }
    }
    return ret;
}


struct OutputStream
{
    mem.Allocator allocator;
    ubyte* data;
    size_t capacity;
    size_t size;

    void dispose()
    {
        if (data)
            allocator.free(data[0 .. capacity]);
    }

    bool empty()
    {
        return size == 0;
    }

    void reserve(int s)
    {
        if (s <= capacity)
            return;

        ubyte* tmp = allocator.alloc!(ubyte)(s).ptr;

        mem.memcpy(tmp, data, capacity);

        allocator.free(data[0 .. capacity]);

        data = tmp;
        capacity = s;
    }

    void resize(int s)
    {
        size = s;
        if (s <= capacity)
            return;
        ubyte* tmp = allocator.alloc!(ubyte)(s).ptr;
        mem.memcpy(tmp, data, capacity);
        
        allocator.free(data[0 .. capacity]);

        data = tmp;
        capacity = s;
    }

    ubyte[] slice()
    {
        return data[0 .. size];
    }
}

struct InputFile
{
    void* handle;

    void dispose()
    {
        assert(!handle);
    }

    bool open(const(char)[] path)
    {
        version (Windows)
        {
            handle = cast(HANDLE) CreateFileA(path.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
            return INVALID_HANDLE_VALUE != handle;
        }
        else version (Posix)
        {
            handle = cast(void*) fopen(path.ptr, "rb");
            return handle != null;
        }
        else
            assert(0);
    }

    void close()
    {
        version (Windows)
        {
            if (INVALID_HANDLE_VALUE != cast(HANDLE) handle)
            {
                CloseHandle(cast(HANDLE) handle);
                handle = cast(void*) INVALID_HANDLE_VALUE;
            }
        }
        else version (Posix)
        {
            if (handle)
            {
                fclose(cast(FILE*) handle);
                handle = null;
            }
        }
        else
        {

        }
    }

    int size()
    {
        version (Windows)
        {
            assert(INVALID_HANDLE_VALUE != handle);
            return GetFileSize(cast(HANDLE) handle, null);
        }
        else version (Posix)
        {
            assert(null != handle);
            size_t pos = ftell(cast(FILE*) handle);
            fseek(cast(FILE*) handle, 0, SEEK_END);
            size_t size = cast(size_t) ftell(cast(FILE*) handle);
            fseek(cast(FILE*) handle, pos, SEEK_SET);
            return cast(int) size;
        }
        else
            assert(0);
    }

    bool read(void* buffer, size_t size)
    {
        version (Windows)
        {
            assert(INVALID_HANDLE_VALUE != handle);
            DWORD readed = 0;
            int success = ReadFile(cast(HANDLE) handle, buffer, cast(DWORD) size, cast(LPDWORD)&readed, null);
            return success && size == readed;
        }
        else version (Posix)
        {
            assert(null != handle);
            size_t read = fread(buffer, size, 1, cast(FILE*) handle);
            return read == 1;
        }
        else
            assert(0);
    }
}

struct OutputFile
{
    void* handle;
    bool is_error;

    bool open(string path)
    {
        version (Windows)
        {
            handle = cast(HANDLE) CreateFileA(path.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
            is_error = INVALID_HANDLE_VALUE == handle;
            return !is_error;
        }
        else version(Posix)
        {
            handle = cast(void*) fopen(path.ptr, "wb");
            is_error = !handle;
            return !is_error;
        }
        else assert(0);
    }

    void close()
    {
        version (Windows)
        {
            if (INVALID_HANDLE_VALUE != cast(HANDLE)handle)
            {
                CloseHandle(cast(HANDLE) handle);
                handle = cast(void*) INVALID_HANDLE_VALUE;
            }
        }
        else version(Posix)
        {
            if (handle)
            {
                fclose(cast(FILE*)handle);
                handle = null;
            }
        }
        else assert(0);
    }

    bool write(const(void)* data, size_t size)
    {
        version (Windows)
        {
            assert(INVALID_HANDLE_VALUE != cast(HANDLE)handle);
            ulong written = 0;
            WriteFile(cast(HANDLE) handle, data, cast(DWORD)size, cast(LPDWORD)&written, null);
            is_error = is_error || size != written;
            return !is_error;
        }
        else version(Posix)
        {
            assert(handle);
            auto written = fwrite(data, size, 1, cast(FILE*)handle);
            return written == 1;
        }
        else assert(0);
    }

    void flush()
    {
        version (Windows)
        {
            assert(null != handle);
            FlushFileBuffers(cast(HANDLE) handle);
        }
        else version(Posix)
        {
            assert(handle);
            fflush(cast(FILE*)handle);
        }
        else assert(0);
    }
}

struct File 
{
    void* handle;
    bool is_error;

    void dispose()
    {
        assert(!handle);
    }

    bool open(const(char)[] path)
    {
        version (Windows)
        {
            handle = cast(HANDLE) CreateFileA(path.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
            return INVALID_HANDLE_VALUE != handle;
        }
        else version (Posix)
        {
            handle = cast(void*) fopen(path.ptr, "rb");
            return handle != null;
        }
        else
            assert(0);
    }

    void close()
    {
        version (Windows)
        {
            if (INVALID_HANDLE_VALUE != cast(HANDLE) handle)
            {
                CloseHandle(cast(HANDLE) handle);
                handle = cast(void*) INVALID_HANDLE_VALUE;
            }
        }
        else version (Posix)
        {
            if (handle)
            {
                fclose(cast(FILE*) handle);
                handle = null;
            }
        }
        else
        {

        }
    }

    int size()
    {
        version (Windows)
        {
            assert(INVALID_HANDLE_VALUE != handle);
            return GetFileSize(cast(HANDLE) handle, null);
        }
        else version (Posix)
        {
            assert(null != handle);
            size_t pos = ftell(cast(FILE*) handle);
            fseek(cast(FILE*) handle, 0, SEEK_END);
            size_t size = cast(size_t) ftell(cast(FILE*) handle);
            fseek(cast(FILE*) handle, pos, SEEK_SET);
            return cast(int) size;
        }
        else
            assert(0);
    }

    bool read(void* buffer, size_t size)
    {
        version (Windows)
        {
            assert(INVALID_HANDLE_VALUE != handle);
            DWORD readed = 0;
            int success = ReadFile(cast(HANDLE) handle, buffer, cast(DWORD) size, cast(LPDWORD)&readed, null);
            return success && size == readed;
        }
        else version (Posix)
        {
            assert(null != handle);
            size_t read = fread(buffer, size, 1, cast(FILE*) handle);
            return read == 1;
        }
        else
            assert(0);
    }

    bool write(const(void)* data, size_t size)
    {
        version (Windows)
        {
            assert(INVALID_HANDLE_VALUE != cast(HANDLE)handle);
            ulong written = 0;
            WriteFile(cast(HANDLE) handle, data, cast(DWORD)size, cast(LPDWORD)&written, null);
            is_error = is_error || size != written;
            return !is_error;
        }
        else version(Posix)
        {
            assert(handle);
            auto written = fwrite(data, size, 1, cast(FILE*)handle);
            return written == 1;
        }
        else assert(0);
    }

    void flush()
    {
        version (Windows)
        {
            assert(null != handle);
            FlushFileBuffers(cast(HANDLE) handle);
        }
        else version(Posix)
        {
            assert(handle);
            fflush(cast(FILE*)handle);
        }
        else assert(0);
    }
}


File open_file(const(char)[] path)
{
    File file;
    file.open(path);
    return file;
}


struct FS
{
    alias content_cb_t = void delegate(uint, const(ubyte)*, bool);
    enum AsyncHandle invalid_handle = {value: 0xffFFffFF};
    struct AsyncHandle
    {
        uint value = 0;
        bool is_valid()
        {
            return value != 0xffFFffFF;
        }
    }

    struct AsyncItem
    {
        enum Flags
        {
            FAILED = 1 << 0,
            CANCELED = 1 << 1
        }

        content_cb_t cb;
        OutputStream data;
        char[256] path = 0;
        ubyte flags = 0;
        uint id = 0;
        void* usr;

        bool is_failed()
        {
            return (flags & Flags.FAILED) == true;
        }

        bool is_canceled()
        {
            return (flags & Flags.CANCELED) == true;
        }
    }

    char[256] base_path = 0;
    Array!AsyncItem queue;
    Array!AsyncItem finished;
    uint work_counter = 0;
    
    version (HAS_THREADS)
    {
        import rt.thread;

        Thread task;
        Mutex mutex;
        Semaphore semaphore;
    }
    
    uint last_id;
    bool done;

    mem.Allocator allocator;

    void create(mem.Allocator allocator)
    {
        this.allocator = allocator;
        queue.create(allocator);
        finished.create(allocator);

        version (HAS_THREADS)
        {
            mutex.create();
            semaphore.create();
            task.name = "fs_worker";
            task.create((ctx, t) {
                FS* fs = cast(FS*) ctx;
                assert(fs, "fs null");

                while (!fs.done)
                {
                    fs.semaphore.wait();
                    if (fs.done)
                        break;

                    char[256] path = 0;
                    {
                        fs.mutex.enter();
                        scope (exit)
                            fs.mutex.exit();

                        assert(!fs.queue.empty(), "queue empty");

                        path = fs.queue[0].path;
                        if (fs.queue[0].is_canceled())
                        {
                            fs.queue.remove_at(0);
                            continue;
                        }
                    }

                    OutputStream data;
                    data.allocator = fs.allocator;
                    bool success = fs.get_content_sync(cast(string) path, &data);
                    {
                        fs.mutex.enter();
                        scope (exit)
                            fs.mutex.exit();

                        if (!fs.queue[0].is_canceled())
                        {
                            fs.finished.add(fs.queue[0]);
                            fs.finished.back().data = data;
                            if (!success)
                            {
                                fs.finished.back().flags |= AsyncItem.Flags.FAILED;
                            }
                        }
                        fs.queue.remove_at(0);
                    }
                }
            }, &this);

            task.start();
        }
    }

    void dispose()
    {
        done = true;
        version (HAS_THREADS)
        {
            task.terminate();
            mutex.dispose();
            semaphore.dispose();
        }
        queue.dispose();
        finished.dispose();
    }

    bool get_content_sync(string path, ubyte[] buffer)
    {
        assert(path.length > 0);

        InputFile file;

        auto fullpath = path; // TODO: concat with base batch

        if (!file.open(cast(string) fullpath))
        {
            LWARN("can't open {}", fullpath.ptr);
            return false;
        }

        auto filesize = file.size();
        assert(buffer.length > filesize);

        if (!file.read(buffer.ptr, filesize))
        {
            file.close();
            return false;
        }
        file.close();
        return true;
    }

    bool get_content_sync(string path, OutputStream* stream)
    {
        assert(path.length > 0);

        InputFile file;

        auto fullpath = path; // TODO: concat with base batch

        if (!file.open(cast(string) fullpath))
        {
            LWARN("can't open {}", fullpath.ptr);
            return false;
        }

        auto filesize = file.size();
        stream.resize(filesize);

        if (!file.read(stream.data, stream.size))
        {
            file.close();
            return false;
        }
        file.close();
        return true;
    }

    AsyncHandle get_content_async(string path, scope content_cb_t callback)
    {
        assert(path.length > 0);
        assert(path.length <= 256);

        version (HAS_THREADS)
            mutex.enter();
        version (HAS_THREADS)
            scope (exit)
                mutex.exit();

        ++work_counter;
        AsyncItem* item = queue.add_get(AsyncItem());
        item.data.allocator = allocator;
        ++last_id;
        if (last_id == 0)
            ++last_id;
        item.id = last_id;

        auto len = str_len(path.ptr);
        mem.memcpy(item.path.ptr, path.ptr, len);
        item.path[len] = '\0';

        item.cb = callback;

        version (HAS_THREADS)
            semaphore.signal();

        version (WebAssembly)
            js_load_file_async(path, item.id, &on_wasm_cp);

        return AsyncHandle(item.id);
    }

    version (WebAssembly) extern (C) void on_wasm_cp(uint id, void* ptr, int len, bool ok)
    {
        scope (exit) if (ok) allocator.free(ptr[0 .. len]);

        int index = -1;
        foreach (i, ref AsyncItem q; queue)
        {
            if (q.id == id)
            {
                index = i;
                if (q.is_canceled())
                {
                    LINFO("canceled {}", id);
                    break;
                }
                if (!ok)
                {
                    LWARN("failed {}", id);
                    q.flags |= AsyncItem.Flags.FAILED;
                }
                else
                {
                    q.data.resize(len);
                    mem.memcpy(q.data.data, ptr, len);
                }

                finished.add(q);
                break;
            }
        }
        assert(index >= 0);

        queue.remove_at(index);
    }

    void cancel(AsyncHandle async)
    {
        version (HAS_THREADS)
            mutex.enter();
        version (HAS_THREADS)
            scope (exit)
                mutex.exit();

        foreach (ref AsyncItem item; queue)
        {
            if (item.id == async.value)
            {
                item.flags |= AsyncItem.Flags.CANCELED;
                --work_counter;
                return;
            }
        }
        foreach (ref AsyncItem item; finished)
        {
            if (item.id == async.value)
            {
                item.flags |= AsyncItem.Flags.CANCELED;
                return;
            }
        }
    }

    void process_callbacks()
    {
        StopWatch timer;
        timer.start();
        for (;;)
        {
            version (HAS_THREADS)
                mutex.enter();
            if (finished.empty())
            {
                version (HAS_THREADS)
                    mutex.exit();
                break;
            }

            AsyncItem item = finished[0];
            finished.remove_at(0);
            assert(work_counter > 0);
            --work_counter;

            version (HAS_THREADS)
                mutex.exit();

            if (!(item.is_canceled()))
            {
                item.cb(cast(uint)item.data.size, item.data.data, !item.is_failed());
            }

            item.data.dispose();

            if (timer.elapsed().msecs() > 1)
            {
                break;
            }
        }
    }
}

version (WebAssembly)
{
}
else
{
    import core.stdc.stdlib: getenv;

    version (Windows)
    {
        import core.sys.windows.winbase: GetFileAttributes;
        import core.stdc.stdio: fread, fwrite, fopen, fclose, FILE;
        extern (C) int _mkdir(const(char)* path);
    }
    else version(Posix)
    {
        import core.sys.posix.sys.stat: mkdir;
        import core.stdc.stdio: fread, fwrite, fopen, fclose;
    }

    bool dir_exist(const(char)* path)
    {
        version(Windows)
        {
	        enum uint INVALID_FILE_ATTRIBUTES = -1;
	        enum uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
            auto dwAttrib = GetFileAttributes(cast(const(wchar)*) path);
            return (dwAttrib != INVALID_FILE_ATTRIBUTES  && (dwAttrib & FILE_ATTRIBUTE_DIRECTORY));

        }
        else version(Posix)
        {
            // TODO: test
            return file_exist(path);
        }
        else static assert(0);
    }

    bool file_exist(const(char)* path)
    {
        FILE *fptr = fopen(path,"rb");
        if (!fptr) return false;

        fclose(fptr);
        return true;
    }

    bool create_dir(char* path)
    {
        FILE *fptr = fopen(path,"rb");
        if (fptr) 
        {
            fclose(fptr);
            return true;
        }
        version(Windows)
            return _mkdir(path) == 0;
        else version(Posix)
            return mkdir(path, 493) == 0; // 0755
        else static assert(0);
    }
}




bool copy_file(const(char)* from, const(char)* to) {
    version(Windows) {
        import core.sys.windows.windows: DeleteFile, CopyFileA, LPCSTR;

        // TODO: why wchar
        auto ret = CopyFileA(cast(LPCSTR) from, cast(LPCSTR) to, 0);

        LINFO("copy: {}", ret);
        return ret == 1 ? true : false;
    } else version (linux) {
        import core.sys.posix.stdio: FILE, remove, popen, pclose, sprintf, fopen, fread, fwrite, fclose;
        FILE* fsrc;
        FILE* fdest;
        ubyte[512] buffer;
        size_t bytes;

        fsrc = fopen(from, "rb");
        if ( fsrc == null)
           return false; //LERRO("failed to open file: {} for reading\n", source);

        fdest = fopen(to, "wb");
        if ( fdest == null)
           return false; //LERRO("failed to open file: {} for reading\n", target);

        while ( (bytes = fread(buffer.ptr, 1, (buffer.length), fsrc)) > 0 )
        {
           fwrite(buffer.ptr, 1, bytes, fdest);
        }

        fclose(fsrc);
        fclose(fdest);
        return true;
    } else {
        return false;
    }
}

void remove_file(string file) {
    version(Windows) {
        import core.sys.windows.windows: DeleteFile, CopyFile;
        DeleteFile(cast(wchar*) file.ptr);
    } else version (linux) {
        import core.sys.posix.stdio: FILE, remove, popen, pclose, sprintf, fopen, fread, fwrite, fclose;
        remove(file.ptr);
    } else {
        return;
    }
}