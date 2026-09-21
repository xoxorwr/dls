module dls.io;

import rt.dbg;
import rt.filesystem;
import mem = rt.memz;

import core.stdc.stdio;
import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.ctype;

/// Capacity the open-document table starts with; it grows from there.
enum INITIAL_BUFFER_CAPACITY = 64;

struct DOCUMENT_LOCATION {
    const (char) * uri;
    int line;
    int character;
}

struct BUFFER {
    char* uri;
    char* content;
}

__gshared BUFFER* buffers;
__gshared int buffers_capacity;
__gshared int first_empty_buf;

/**
 * Grows the open-document table, doubling its capacity, and returns false
 * when the allocator is out of memory.
 *
 * The table had a fixed 'BUFFER_LENGTH' of 128 entries: opening one document
 * more silently dropped it (the buffer was never tracked, so every request
 * for it answered with an empty result until some other document was closed).
 * There is no eviction -- only 'close_buffer' frees a slot -- so the table
 * has to grow instead.
 *
 * The buffers outlive a request frame, so 'alloc' must be the long-lived
 * allocator stored in main.d, not the per-request arena, and the same
 * allocator must be used for every buffer in the table.
 */
bool grow_buffers(mem.Allocator alloc) {
    auto capacity = buffers_capacity == 0 ? INITIAL_BUFFER_CAPACITY : buffers_capacity * 2;

    auto grown = alloc.alloc!BUFFER(capacity);
    if (grown.length != capacity) {
        LERRO("out of memory growing the buffer table to {} documents", capacity);
        return false;
    }

    foreach (i; 0 .. buffers_capacity)
        grown[i] = buffers[i];
    // The slots past the high-water mark are only written on insert, but the
    // table is scanned by 'first_empty_buf' and freed by capacity, so leave
    // no uninitialised entries behind.
    foreach (i; buffers_capacity .. capacity)
        grown[i] = BUFFER.init;

    if (buffers != null)
        alloc.free(buffers[0 .. buffers_capacity]);

    buffers = grown.ptr;
    buffers_capacity = capacity;
    LINFO("buffer table grown to {} documents", capacity);
    return true;
}

/**
 * Returns the index of the buffer for 'uri', or -1 when it isn't open.
 */
int find_buffer_index(const char * uri) {
    if (uri == null) return -1;
    for (int i = 0; i < first_empty_buf; i++) {
        if (strcmp(buffers[i].uri, uri) == 0) return i;
    }
    return -1;
}

/**
 * Reads 'uri' (a path, optionally prefixed with file://) into a freshly
 * allocated, null-terminated string, or returns null when it can't be read.
 * The caller owns the memory and releases it with 'free_cstring'.
 */
char* read_file_cstring(mem.Allocator alloc, const char * uri) {
    auto diskPath = uri[0 .. strlen(uri)];
    if (diskPath.length > 7 && diskPath[0 .. 7] == "file://")
        diskPath = diskPath[7 .. $];

    File file;
    auto exist = file.open(diskPath);
    if (!exist)
    {
        LWARN("file: '{}' doesn't exist", uri);
        return null;
    }
    auto s = file.size();
    auto b = alloc.alloc!char(s + 1);
    b[s] = 0;
    file.read(b.ptr, s);
    return b.ptr;
}

/// Duplicates a C string through 'alloc' (null-terminated).
char* dup_cstring(mem.Allocator alloc, const char * str) {
    auto len = strlen(str);
    auto ret = alloc.alloc!char(len + 1);
    memcpy(ret.ptr, str, len);
    ret[len] = 0;
    return ret.ptr;
}

/// Releases a string produced by 'dup_cstring' / 'read_file_cstring'.
void free_cstring(mem.Allocator alloc, char* str) {
    if (str == null) return;
    alloc.free(str[0 .. strlen(str) + 1]);
}

/**
 * Opens (or re-opens) the buffer for 'uri'.  Buffers outlive a request frame
 * - they are kept until the document is closed - so 'alloc' must be a
 * long-lived allocator (mem.c_allocator), not the per-request arena.
 */
BUFFER open_buffer(mem.Allocator alloc, const char * uri, const char * content) {
    if (uri == null) {
        LWARN("open_buffer called without a uri");
        return BUFFER.init;
    }

    // Opening a document that is already tracked replaces its text instead of
    // adding a second entry: a duplicate didOpen must not leave the URI half
    // closed when the client later sends didClose.
    auto existing = find_buffer_index(uri);
    if (existing >= 0) {
        char* text = cast(char*) content;
        if (text == null) {
            LWARN("buffer '{}' doesn't exist, reading it now", uri);
            text = read_file_cstring(alloc, uri);
            if (text == null) return BUFFER.init;
        }
        auto newContent = dup_cstring(alloc, text);
        free_cstring(alloc, buffers[existing].content);
        buffers[existing].content = newContent;
        return buffers[existing];
    }

    if (first_empty_buf >= buffers_capacity && !grow_buffers(alloc))
        return BUFFER.init;

    if (content == null)
    {
        LWARN("buffer '{}' doesn't exist, reading it now", uri);
        auto text = read_file_cstring(alloc, uri);
        if (text == null) return BUFFER.init;
        buffers[first_empty_buf].uri = dup_cstring(alloc, uri);
        buffers[first_empty_buf].content = text;
    }
    else
    {
        buffers[first_empty_buf].uri = dup_cstring(alloc, uri);
        buffers[first_empty_buf].content = dup_cstring(alloc, content);
    }
    return buffers[first_empty_buf++];
}

BUFFER update_buffer(mem.Allocator alloc, const char * uri, const char * content) {
    if (uri == null) {
        LWARN("update_buffer called without a uri");
        return BUFFER.init;
    }

    if (find_buffer_index(uri) < 0)
        // A change for a document the server never saw opened: keep the text
        // instead of dropping it (or worse, killing the process).
        LWARN("change for un-opened buffer '{}', opening it", uri);

    return open_buffer(alloc, uri, content);
}

/**
 * Returns the buffer for 'uri', or a null-initialised BUFFER when the
 * document isn't open.  Callers must check 'buffer.content !is null'.
 */
BUFFER get_buffer(const char * uri) {
    auto index = find_buffer_index(uri);
    if (index >= 0) return buffers[index];
    LWARN("no open buffer for '{}'", uri);
    return BUFFER.init;
}

bool has_buffer(const char * uri) {
    return find_buffer_index(uri) >= 0;
}

BUFFER get_or_open_buffer(mem.Allocator alloc, const char* uri)
{
    if (uri == null) return BUFFER.init;
    auto index = find_buffer_index(uri);
    if (index >= 0) return buffers[index];
    return open_buffer(alloc, uri, null);
}

void close_buffer(mem.Allocator alloc, const char * uri) {
    auto i = find_buffer_index(uri);
    if (i < 0) {
        LWARN("close for un-opened buffer '{}'", uri);
        return;
    }
    free_cstring(alloc, buffers[i].uri);
    free_cstring(alloc, buffers[i].content);
    for (int j = i; j < first_empty_buf - 1; j++) {
        buffers[j] = buffers[j + 1];
    }
    --first_empty_buf;
}


void truncate_string(char * text, int line, int character) {
    uint position = 0;
    for (int i = 0; i < line; i++) {
        position += strcspn(text + position, "\n") + 1;
    }
    position += character;

    if (position >= strlen(text)) {
        return;
    }

    while (isalnum( * (text + position))) {
        ++position;
    }
    text[position] = '\0';
}

size_t[2] lineByteRangeAt(string text, uint line) {
    size_t start = 0;
    size_t index = 0;
    while (line > 0 && index < text.length) {
        const c = text.ptr[index++];
        if (c == '\n') {
            line--;
            start = index;
        }
    }
    // if !found
    if (line != 0)
        return [0, 0];

    int end = -1;

    for (size_t i = start; i < text.length; i++)
        if (text[i] == '\n') {
            end = cast(int) i;
            break;
        }
    if (end == -1)
        end = cast(int) text.length;
    else
        end++;

    return [start, end];
}
pragma(inline, true) void utf16DecodeUtf8Length(A, B)(char c, ref A utf16Index,
    ref B utf8Index) {
    switch (c & 0b1111_0000) {
    case 0b1110_0000:
        // assume valid encoding (no wrong surrogates)
        utf16Index++;
        utf8Index += 3;
        break;
    case 0b1111_0000:
        utf16Index += 2;
        utf8Index += 4;
        break;
    case 0b1100_0000:
    case 0b1101_0000:
        utf16Index++;
        utf8Index += 2;
        break;
    default:
        utf16Index++;
        utf8Index++;
        break;
    }
}

int positionToBytes(string text, int line, int character) {
    int index = 0;
    while (index < text.length && line > 0)
        if (text.ptr[index++] == '\n')
            line--;

    while (index < text.length && character > 0) {
        auto c = text.ptr[index];
        if (c == '\n')
            break;
        size_t utf16Size;
        utf16DecodeUtf8Length(c, utf16Size, index);
        if (utf16Size < character)
            character -= utf16Size;
        else
            character = 0;
    }
    return index;
}


struct Position
{
    size_t line;
    size_t character;

    int opCmp(const Position other) const
    {
        if (line < other.line)
            return -1;
        if (line > other.line)
            return 1;
        if (character < other.character)
            return -1;
        if (character > other.character)
            return 1;
        return 0;
    }
}
Position bytesToPosition(string text, size_t bytes)
{
    if (bytes > text.length)
        bytes = text.length;
    auto part = text.ptr[0 .. bytes];
    size_t lastNl = -1;
    Position ret;
    foreach (i; 0 .. bytes)
    {
        if (part.ptr[i] == '\n')
        {
            ret.line++;
            lastNl = i;
        }
    }
    ret.character = cast(uint)(cast(const(char)[]) part[lastNl + 1 .. $]).countUTF16Length;
    return ret;
}

size_t countUTF16Length(scope const(char)[] text)
{
    size_t offset;
    size_t index;
    while (index < text.length)
    {
        const c = (() @trusted => text.ptr[index++])();
        if (cast(byte)c >= -0x40) offset++;
        if (c >= 0xf0) offset++;
    }
    return offset;
}
