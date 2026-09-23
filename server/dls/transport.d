module dls.transport;

import rt.dbg;
import mem = rt.memz;

import core.stdc.string;
import core.stdc.stdlib : atoi;

/**
 * The input side of the protocol: `Content-Length` framed messages read from
 * standard input.
 *
 * The messages are read into one buffer instead of through the C runtime's
 * `stdin`, so that what the client has already sent can be looked at before
 * the message in hand is answered (see 'queued_messages'): a request the
 * client cancelled, or one about a text a queued change has replaced, is not
 * worth computing.  Nothing is consumed by looking; 'next_message' hands the
 * messages out in order.
 */

__gshared private {
    mem.Allocator g_alloc;
    char[] g_input;
    /// The unconsumed bytes are 'g_input[g_start .. g_end]'.
    size_t g_start;
    size_t g_end;
    /// Standard input reached its end (or failed): nothing more will come.
    bool g_eof;
}

/// 'alloc' must outlive every request (the buffer is kept for the session).
void transport_init(mem.Allocator alloc) {
    g_alloc = alloc;
}

/**
 * The body of the next message, copied into 'alloc' and null terminated, or
 * null once the input ended before a whole message.  Waits for the client.
 */
char[] next_message(mem.Allocator alloc) {
    while (true) {
        size_t body_start, body_length;
        if (frame_at(g_start, body_start, body_length)) {
            auto body_ = alloc.alloc!char(body_length + 1);
            if (body_.length != body_length + 1) {
                LERRO("out of memory reading a message of {} bytes", body_length);
                return null;
            }
            memcpy(body_.ptr, g_input.ptr + body_start, body_length);
            body_[body_length] = 0;
            g_start = body_start + body_length;
            if (g_start == g_end)
                g_start = g_end = 0;
            return body_[0 .. body_length];
        }
        if (!read_input(true))
            return null;
    }
}

/**
 * Calls 'visit' with the body of every whole message the client has sent
 * beyond the one being handled, oldest first, until it returns true; returns
 * whether it did.  Never waits: only what is readable right now is read.
 *
 * The bodies are slices of the input buffer, not null terminated, and only
 * valid during the call.
 */
bool queued_messages(scope bool delegate(const(char)[] body_) visit) {
    // Whatever has arrived since the last read; bounded, so a client that
    // keeps writing cannot keep the answer from going out.
    foreach (_; 0 .. 64)
        if (!read_input(false))
            break;

    size_t at = g_start;
    size_t body_start, body_length;
    while (frame_at(at, body_start, body_length)) {
        if (visit(g_input[body_start .. body_start + body_length]))
            return true;
        at = body_start + body_length;
    }
    return false;
}

/**
 * Whether a whole message starts at 'at': its header lines, an empty line,
 * then 'Content-Length' bytes of body.  Headers other than 'Content-Length'
 * are skipped, and so are empty lines before the length is known.
 */
private bool frame_at(size_t at, out size_t body_start, out size_t body_length) {
    size_t content_length = 0;
    size_t line_start = at;
    while (true) {
        size_t line_end = line_start;
        while (line_end < g_end && g_input[line_end] != '\n')
            line_end++;
        if (line_end >= g_end)
            return false; // the header is not all here yet

        auto line = g_input[line_start .. line_end];
        if (line.length > 0 && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        line_start = line_end + 1;

        if (line.length == 0) {
            if (content_length == 0)
                continue;
            if (g_end - line_start < content_length)
                return false; // the body is not all here yet
            body_start = line_start;
            body_length = content_length;
            return true;
        }

        enum name = "Content-Length:";
        if (line.length > name.length && line[0 .. name.length] == name) {
            auto value = line[name.length .. $];
            size_t n = 0;
            foreach (c; value) {
                if (c == ' ' || c == '\t') {
                    if (n == 0) continue;
                    break;
                }
                if (c < '0' || c > '9')
                    break;
                n = n * 10 + (c - '0');
            }
            content_length = n;
        }
    }
}

/**
 * Appends what standard input has to the buffer.  With 'wait', blocks until
 * something arrives; without, only reads what is already there.  Returns
 * whether anything was read.
 */
private bool read_input(bool wait) {
    if (g_eof)
        return false;
    if (!wait && !input_ready())
        return false;

    enum CHUNK = 64 * 1024;
    if (!reserve(CHUNK))
        return false;

    auto count = read_stdin(g_input.ptr + g_end, g_input.length - g_end);
    if (count <= 0) {
        g_eof = true;
        return false;
    }
    g_end += count;
    return true;
}

/// Room for 'extra' bytes past 'g_end': the consumed front is reclaimed
/// first, and the buffer grows when that is not enough.
private bool reserve(size_t extra) {
    if (g_input.length - g_end >= extra)
        return true;

    if (g_start > 0) {
        memmove(g_input.ptr, g_input.ptr + g_start, g_end - g_start);
        g_end -= g_start;
        g_start = 0;
        if (g_input.length - g_end >= extra)
            return true;
    }

    auto capacity = g_input.length == 0 ? extra * 2 : g_input.length * 2;
    while (capacity - g_end < extra)
        capacity *= 2;
    auto grown = g_alloc.alloc!char(capacity);
    if (grown.length != capacity) {
        LERRO("out of memory growing the input buffer to {} bytes", capacity);
        return false;
    }
    if (g_end > 0)
        memcpy(grown.ptr, g_input.ptr, g_end);
    if (g_input.length > 0)
        g_alloc.free(g_input);
    g_input = grown;
    return true;
}

version (Windows) {
    import core.sys.windows.windows : GetStdHandle, ReadFile, PeekNamedPipe,
        STD_INPUT_HANDLE, DWORD, HANDLE;

    /// Whether reading would not block.  Only a pipe can be asked that - an
    /// editor always starts the server on one; anything else never looks
    /// ahead, which only costs the chance to skip work.
    private bool input_ready() {
        DWORD available;
        if (!PeekNamedPipe(GetStdHandle(STD_INPUT_HANDLE), null, 0, null, &available, null))
            return false;
        return available > 0;
    }

    private ptrdiff_t read_stdin(char* buffer, size_t length) {
        DWORD read;
        if (!ReadFile(GetStdHandle(STD_INPUT_HANDLE), buffer, cast(DWORD) length, &read, null))
            return -1; // a closed pipe (the client exited) included
        return read;
    }
} else {
    import core.sys.posix.poll : poll, pollfd, POLLIN, POLLHUP;
    import core.sys.posix.unistd : read;
    import core.stdc.errno : errno, EINTR;

    private bool input_ready() {
        pollfd fd = { fd: 0, events: POLLIN };
        return poll(&fd, 1, 0) > 0 && (fd.revents & (POLLIN | POLLHUP)) != 0;
    }

    private ptrdiff_t read_stdin(char* buffer, size_t length) {
        while (true) {
            auto count = read(0, buffer, length);
            if (count < 0 && errno == EINTR)
                continue;
            return count;
        }
    }
}
