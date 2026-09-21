module rt.memz;

import rt.dbg;


extern(C) void d_assert(int exp)
{
    if (!exp)
        assert(0);
}

version (WebAssembly)
{
    import rt.wasm;
}
else
{
    import stdc = core.stdc.stdio;
    import stdlib = core.stdc.stdlib;
    import stdc_str = core.stdc.string;

    private alias uintptr_t = size_t;
}

version (WebAssembly)
{

    private {
    alias uint32_t = uint;
    alias uint8_t = ubyte;
    alias uintptr_t = uint;

    __gshared uint32_t[32] freeHeads = 0;
    __gshared uint32_t[32] freeTails = 0;
    __gshared uint32_t freePages = 0;
    __gshared uint32_t freeStart = 0;
    __gshared uint32_t[65536] pageBuckets = 0;
    }

    export extern (C) void* calloc(size_t m, size_t n)
    {
        // musl
        void* p;
        size_t* z;
        if (n && m > cast(size_t) - 1 / n)
        {
            // errno = ENOMEM;
            return null;
        }
        n *= m;
        p = malloc(n);
        if (!p)
            return null;
        /* Only do this for non-mmapped chunks */
        if ((cast(size_t*) p)[-1] & 7)
        {
            /* Only write words that are not already zero */
            m = (n + (*z).sizeof - 1) / (*z).sizeof;
            for (z = cast(size_t*)p; m; m--, z++)
            {

                if (*z)
                {
                    *z = 0;
                }
            }
        }
        return p;
    }


    // TODO: clz is probably wrong!
    export extern (C) void* malloc(size_t size)
    {
        if (size < 4)
            size = 4;
        uint32_t bucket = (clz(size - 1) ^ 31) + 1;
        if (freeHeads[bucket] == 0 && freeTails[bucket] == 0)
        {
            uint32_t wantPages = (bucket <= 16) ? 1 : (1 << (bucket - 16));
            if (freePages < wantPages)
            {
                uint32_t currentPages = llvm_wasm_memory_size(0);
                if (freePages == 0)
                    freeStart = currentPages << 16;
                uint32_t plusPages = currentPages;
                if (plusPages > 256)
                    plusPages = 256;
                if (plusPages < wantPages - freePages)
                    plusPages = wantPages - freePages;

                auto g = llvm_wasm_memory_grow(0, plusPages);
                if (g == -1)
                    assert(0, "you can't");
                else
                    update_memory_view();
                freePages += plusPages;
            }
            pageBuckets[freeStart >> 16] = bucket;
            freeTails[bucket] = freeStart;
            freeStart += wantPages << 16;
            freePages -= wantPages;
        }
        if (freeHeads[bucket] == 0)
        {
            freeHeads[bucket] = freeTails[bucket];
            freeTails[bucket] += 1 << bucket;
            if ((freeTails[bucket] & 0xFFFF) == 0)
                freeTails[bucket] = 0;
        }
        uint32_t result = freeHeads[bucket];
        freeHeads[bucket] = (cast(uint32_t*)(result))[0];
        return cast(void*)(result);
    }

    export extern (C) void free(void* ptr)
    {
        uint32_t p = cast(uint32_t)(ptr);
        size_t bucket = pageBuckets[p >> 16];
        (cast(uint32_t*)(p))[0] = freeHeads[bucket];

        freeHeads[bucket] = p;
    }

    export extern(C) void* realloc(void* ptr, size_t nsize)
    {
        if (!ptr)
        {
            return malloc(nsize);
        }
        else
        {
            // TODO: optimize
            free(ptr);
            return malloc(nsize);
        }
    }
}
else
{


    void* calloc(size_t nmemb, size_t size)
    {
        return stdlib.calloc(nmemb, size);
    }

    void* malloc(size_t size)
    {
        return stdlib.malloc(size);
    }

    void free(void* ptr)
    {
        stdlib.free(ptr);
    }

    void* realloc(void* ptr, size_t size)
    {
        return stdlib.realloc(ptr, size);
    }

    alias memmove = stdc_str.memmove;
}


version (WebAssembly)
{
    extern(C) void OVERFLOW_MEMSET();
    extern(C) void OVERFLOW_MEMCPY();

    pragma(inline, false)
    extern(C) int memcmp(const (void)*vl, const (void)*vr, size_t n)
    {
        const (ubyte) *l=cast(const(ubyte)*)vl;
        const (ubyte) *r=cast(const(ubyte)*)vr;

        // XXX EMSCRIPTEN: add an optimized version.
        // #if !defined(EMSCRIPTEN_OPTIMIZE_FOR_OZ) && !__has_feature(address_sanitizer)
        // 	// If we have enough bytes, and everything is aligned, loop on words instead
        // 	// of single bytes.
        // 	if (n >= 4 && !((((uintptr_t)l) & 3) | (((uintptr_t)r) & 3))) {
        // 		while (n >= 4) {
        // 			if (*((uint32_t *)l) != *((uint32_t *)r)) {
        // 				// Go to the single-byte loop to find the specific byte.
        // 				break;
        // 			}
        // 			l += 4;
        // 			r += 4;
        // 			n -= 4;
        // 		}
        // 	}
        // #endif

        // #if defined(EMSCRIPTEN_OPTIMIZE_FOR_OZ)
        // #pragma clang loop unroll(disable)
        // #endif

        pragma(LDC_never_inline);
        for (; n && *l == *r; n--, l++, r++){}
        return n ? *l-*r : 0;
    }

    pragma(inline, false)
    extern (C) void* memset(void* str, int c, size_t n)
    {
        ubyte* s = cast(ubyte*) str;
        // #pragma clang loop unroll(disable)
        // pragma(inline, false)
        pragma(LDC_never_inline);
        while (n--)
        {
            *s = cast(ubyte) c;
            s++;
        }
        return str;
    }

    pragma(inline, false)
    extern(C) void *memcpy(void* dest, const(void)* src, size_t n)
    {
        ubyte *d = cast(ubyte*) dest;
        const (ubyte) *s = cast(const(ubyte)*)src;

        for (; n; n--) *d++ = *s++;
        return dest;
    }

    pragma(inline, false)
    extern (C) void* memmove(void* dest, const void* src, size_t n)
    {
        if (dest < src) return memcpy(dest, src, n);
        ubyte *d = cast(ubyte *)dest + n;
        const (ubyte )*s = cast(const (ubyte) *)src + n;
        // #pragma clang loop unroll(disable)
        // pragma(inline, false)
        pragma(LDC_never_inline);
        while(n--) *--d = *--s;
        return dest;
    }
}
else
{
    alias memcpy = stdc_str.memcpy;
    alias memset = stdc_str.memset;
}


bool equals(T)(inout(T)[] lhs, inout(T)[] rhs)
{
    if (lhs.length != rhs.length) return false;
    if (lhs.ptr == rhs.ptr) return true;

    for(size_t i = 0; i < lhs.length; ++i) {
        if(lhs[i] != rhs[i]) {
            return false;
        }
    }
    return true;
}
bool equals(T)(inout(T)* lhs, inout(T)[] rhs)
{
    int lhsLen;
    while (lhs[lhsLen] != '\0')
        lhsLen++;
    if (lhsLen != rhs.length) return false;
    if (lhs == rhs.ptr) return true;

    for(size_t i = 0; i < lhsLen; ++i) {
        if(lhs[i] != rhs[i]) {
            return false;
        }
    }
    return true;
}

int ends_with(T)(inout(T)[] str, inout(T)[] suffix)
{
	if(suffix.length > str.length) return 0;

	auto sl = suffix.length;

	if(str[$-sl .. $] == suffix)
		return 1;

	return 0;
}

int starts_with(T)(inout(T)[] str, inout(T)[] preffix)
{
	if(preffix.length > str.length) return 0;

	auto pl = preffix.length;

	if(str[0 .. pl] == preffix)
		return 1;

	return 0;
}

int index_of(T)(inout(T)[] haystack, scope inout(T)[] needle)
{
    return index_of_linear(haystack, 0, needle);
}

int last_index_of(T)(inout(T)[] haystack, scope inout(T)[] needle)
{
    return last_index_of_linear(haystack, 0, needle);
}

int index_of_start(T)(inout(T)[] haystack, scope inout(T)[] needle)
{
    return index_of_linear(haystack, 0, needle);
}

int index_of_linear(T)(inout(T)[] haystack, int startIndex, scope inout(T)[] needle)
{
    int i = startIndex;
    if (haystack.length < needle.length) return -1;
    const end = haystack.length - needle.length;
    while (i <= end)
    {
        if (equals(haystack[i .. i + needle.length], needle)) return i;

        i += 1;
    }
    return -1;
}

int last_index_of_linear(T)(inout(T)[] haystack, int startIndex, scope inout(T)[] needle)
{
    int i = startIndex;
    if (haystack.length < needle.length) return -1;
    const end = haystack.length - needle.length;
    int found = -1;
    while (i <= end)
    {
        if (equals(haystack[i .. i + needle.length], needle)) found = i;

        i += 1;
    }
    return found;
}


enum c_allocator = Allocator(null, &CAllocator.vt);

struct CAllocator
{
    __gshared AllocatorVT vt = {
        alloc: &allocImpl,
        resize: &resizeImpl,
        free: &freeImpl
    };

    static ubyte[] allocImpl(const void* ptr, size_t len, ubyte ptr_align)
    {
        void* m = malloc(len);
        if (!m) return null;
        return cast(ubyte[]) m[0 .. len];
    }

    static bool resizeImpl(const void* ptr, ubyte[] buf, ubyte buf_align, size_t new_len)
    {
        auto resized = realloc(buf.ptr, new_len);
        if (!resized) return false;
        buf = cast(ubyte[])resized[0 .. new_len];
        return true;
    }

    static void freeImpl(const void* ptr, ubyte[] buf, ubyte buf_align)
    {
        free(buf.ptr);
    }
}

struct ArenaAllocator
{
    struct State
    {
        SinglyLinkedList!(ubyte[]) buffer_list;
        size_t end_index = 0;
    }

    State state;
    Allocator child_allocator;

    Allocator allocator()
    {
        return Allocator.create_it!(ArenaAllocator)(&this);
    }

    static ArenaAllocator create(Allocator backing)
    {
        ArenaAllocator ret = {
            state: {},
            child_allocator: backing
        };
        return ret;
    }

    void dispose()
    {
        int freed = 0;
        auto it = state.buffer_list.first;
        while (it) {
            auto node = it;
            auto next_it = node.next;
            child_allocator.free(node.data);
            it = next_it;
            freed++;
        }

        reset();
    }

    void reset()
    {
        state.end_index = 0;
        state.buffer_list = SinglyLinkedList!(ubyte[])();
    }

    alias BufNode = SinglyLinkedList!(ubyte[]).Node;

    BufNode* create_node(size_t prev_len, size_t minimum_size)
    {
        auto actual_min_size = minimum_size + ((BufNode.sizeof) + 16);
        auto big_enough_len = prev_len + actual_min_size;
        auto len = big_enough_len + big_enough_len / 2;

        auto log2_align = cast(ubyte) BufNode.alignof; // TODO: std.math.log2_int(usize, @alignOf(BufNode));

        auto buf = child_allocator.raw_alloc(len, log2_align);

        // TODO: handle alloc failure

        auto buf_node = cast(BufNode*)buf.ptr;
        buf_node.data = buf;
        buf_node.next = null;

        // LINFO("prepend: {}", buf_node.data.length);
        state.buffer_list.prepend(buf_node);
        state.end_index = 0;
        return buf_node;
    }

    ubyte[] alloc(size_t n, ubyte ptr_align= 0)
    {
        auto cur_node = state.buffer_list.first;
        if (!cur_node)
        {
            // LINFO("alloc node: {}", n + ptr_align);
            cur_node = create_node(0, n + ptr_align);
        }

        while (true)
        {
            auto cur_buf = cur_node.data[(BufNode.sizeof).. $];
            auto addr = cast(int)(cur_buf.ptr) + state.end_index;
            auto adjusted_addr = addr; //TODO: alignment :: mem.alignForward(addr, ptr_align);
            auto adjusted_index = state.end_index + (adjusted_addr - addr);
            auto new_end_index = adjusted_index + n;

            if (new_end_index <= cur_buf.length) {
                auto result = cur_buf[adjusted_index..new_end_index];
                state.end_index = new_end_index;
                return result;
            }

            auto bigger_buf_size = (BufNode.sizeof) + new_end_index;
            // Try to grow the buffer in-place
            // cur_node.data = child_allocator.resize(cur_node.data, bigger_buf_size);

            // assert(cur_node.data);
            // if (!cur_node.data)
            {
                cur_node = create_node(cur_buf.length, n + ptr_align);
                continue;
            }

            // TODO: check me once, since i changed what resize returns, i should
            // properly rething this too

            // orelse {
            //    // Allocate a new node if that's not possible
            //    cur_node = try self.createNode(cur_buf.len, n + ptr_align);
            //    continue;
            //};
        }
    }

    bool resize(ubyte[] buf, ubyte buf_align, size_t new_len)
    {
        // it's an arena, we don't need any of that, do we?
        panic("not yet");
    }

    void free(ubyte[] buf, ubyte buf_align)
    {
        auto cur_node = state.buffer_list.first;
        if (!cur_node) return;

        auto cur_buf = cur_node.data[(BufNode.sizeof).. $];

        if ((cur_buf.ptr) + state.end_index == (buf.ptr) + buf.length) {
            state.end_index -= buf.length;
        }
    }
}

struct Allocator
{
    void* ptr;
    AllocatorVT* vt;
    static Allocator create_it(T)(void* pointer) if (__traits(isPOD, T))
    {
        struct _gen(T)
        {
            __gshared AllocatorVT vt = {
                alloc: &allocImpl,
                resize: &resizeImpl,
                free: &freeImpl
            };
            static ubyte[] allocImpl(const void* ptr, size_t len, ubyte ptr_align)
            {
                auto self = cast(T*) ptr;
                return self.alloc(len, ptr_align);
            }
            static bool resizeImpl(const void* ptr, ubyte[] buf, ubyte buf_align, size_t new_len)
            {
                auto self = cast(T*) ptr;
                return self.resize(buf, buf_align, new_len);
            }

            static void freeImpl(const void* ptr, ubyte[] buf, ubyte buf_align)
            {
                auto self = cast(T*) ptr;
                return self.free(buf, buf_align);
            }
        }
        assert(pointer);
        return Allocator(pointer, &_gen!(T).vt);
    }

    // interface

    ubyte[] raw_alloc(size_t len, ubyte ptr_align = 0)
    {
        return vt.alloc(ptr, len, ptr_align);
    }

    bool raw_resize(ubyte[] buf, ubyte log2_buf_align, size_t new_len)
    {
        return vt.resize(ptr, buf, log2_buf_align, new_len);
    }

    void raw_free(ubyte[] buf, ubyte log2_buf_align)
    {
        vt.free(ptr, buf, log2_buf_align);
    }

    // ---

    // helpers

    T[] alloc(T)(size_t len)
    {
        return cast(T[]) vt.alloc(ptr, len * T.sizeof, 0);
    }

    bool resize(T)(T[] buf, size_t new_len)
    {
        assert(new_len > 0);

        auto size = T.sizeof * buf.length;
        auto newSize = T.sizeof * new_len;
        auto p = cast(ubyte*) buf.ptr;

        return raw_resize( p[0 .. size], 0, newSize);
    }

    void free(T)(T[] buf) /* if (!isPointer!T) */
    {
        auto size = T.sizeof * buf.length;
        auto p = cast(ubyte*) buf.ptr;
        vt.free(ptr, p[0 .. size], 0);
    }

	T* create(T, Args...)(Args args = Args.init)
	{
        import core.lifetime: emplace;
		static assert(is(T == struct), "it's not a struct"); // only structs for now

		auto ptr = raw_alloc(T.sizeof).ptr;
		if (!ptr)
			assert(0, "Out of memory!");

		auto ret = cast(T*) ptr;
		return emplace(ret, args);
	}

    void destroy(T)(T* pointer)
    {
        auto size = T.sizeof;
        auto b = cast(ubyte*) pointer;
        raw_free(b[0 .. size], 0);
    }
}


T[] dupe(T)(Allocator a, const(T)[] orig)
{
    assert(orig.length != 0);

    T[] ret = a.alloc!T(orig.length);

    memcpy(ret.ptr, orig.ptr, orig.length * T.sizeof);

    return ret;
}


T[] dupe_add_sentinel(T)(Allocator a, const(T)[] orig)
{
    assert(orig.length != 0);

    T[] ret = a.alloc!T(orig.length + 1);

    memcpy(ret.ptr, orig.ptr, orig.length * T.sizeof);

    ret[orig.length] = 0;

    return ret;
}


package:

enum bool isPointer(T) = is(T == U*, U) && __traits(isScalar, T);


int clz(size_t x)
{
    if (x == 0)
        return 32;

    __gshared ubyte[32] debruijn32 = [
        0, 31, 9, 30, 3, 8, 13, 29, 2, 5, 7, 21, 12, 24, 28, 19,
        1, 10, 4, 14, 6, 22, 25, 20, 11, 15, 23, 26, 16, 27, 17, 18
    ];
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    x++;
    return debruijn32[x * 0x076be629 >> 27];
}

//int a_clz_64(ulong x)
//{
//	uint y;
//	int r;
//	if (x>>32) y=x>>32, r=0; else y=x, r=32;
//	if (y>>16) y>>=16; else r |= 16;
//	if (y>>8) y>>=8; else r |= 8;
//	if (y>>4) y>>=4; else r |= 4;
//	if (y>>2) y>>=2; else r |= 2;
//	return r | !(y>>1);
//}

//int a_clz_32(uint x)
//{
//	x >>= 1;
//	x |= x >> 1;
//	x |= x >> 2;
//	x |= x >> 4;
//	x |= x >> 8;
//	x |= x >> 16;
//	x++;
//	return 31-a_ctz_32(x);
//}

struct AllocatorVT
{
    alloc_d alloc;
    resize_d resize;
    free_d free;
}

private alias alloc_d = ubyte[] function(const void* self, size_t len, ubyte ptr_align);
private alias resize_d = bool function(const void* self, ubyte[] buf, ubyte buf_align, size_t new_len);
private alias free_d = void function(const void* self, ubyte[] buf, ubyte buf_align);

struct SinglyLinkedList(T)
{
    struct Node
    {
        Node* next = null;
        T data;

        void insert_after(Node* new_node) {
            new_node.next = next;
            next = new_node;
        }

        Node* remove_next() {
            if (!next) return null;

            auto next_node = next;
            next = next_node.next;
            return next_node;
        }

        Node* find_last() {
            auto it = next;
            while (true) {
                if (!it.next) return it;
                it = it.next;
            }
        }

        size_t count_children() {
            size_t count = 0;
            auto it = next;
            while (it)
            {
                count += 1;
                it = it.next;
            }

            return count;
        }
    }

    Node* first = null;

    void prepend(Node* new_node)
    {
        new_node.next = first;
        first = new_node;
    }

    void remove(Node* node)
    {
        if (first == node) {
            first = node.next;
        } else {
            auto current_elm = first;
            while (current_elm.next != node) {
                current_elm = current_elm.next;
            }
            current_elm.next = node.next;
        }
    }

    Node* pop_first()
    {
        auto f = first;
        if (f == null) return null;
        first = f.next;
        return f;
    }

    size_t length()
    {
        if (!first) return 0;
        return 1 + first.count_children();
    }
}
