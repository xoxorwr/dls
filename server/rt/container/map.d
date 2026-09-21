module rt.container.map;

import rt.dbg;
import rt.memz;
import rt.math;


struct HashMap(Key, Value)
{
    enum MIN_HASH_TABLE_POWER = 3;
    enum RELATIONSHIP = 8;
    static struct Pair
    {
        Key key;
        Value value;
    }

    static struct Element
    {
        uint hash = 0;
        Element* next = null;
        Pair pair;
    }

    Element** hash_table = null;
    size_t allocatedSize = 0;
    ubyte hash_table_power = 0;
    uint elements = 0;
    Allocator allocator;

    void create(Allocator alloc)
    {
        allocator = alloc;
    }

    void dispose()
    {
        clear();
    }

    private:
    void make_hash_table()
    {
        auto s = (Element*).sizeof * (1 << MIN_HASH_TABLE_POWER);

        allocatedSize = s;
        hash_table = cast(Element**) allocator.raw_alloc(s).ptr;
        hash_table_power = MIN_HASH_TABLE_POWER;
        elements = 0;
        for (int i = 0; i < (1 << MIN_HASH_TABLE_POWER); i++)
        {
            hash_table[i] = null;
        }
    }

    void erase_hash_table()
    {
        //ERR_FAIL_COND_MSG(elements, "Cannot erase hash table if there are still elements inside.");
        //memdelete_arr(hash_table);

        auto bytes = (cast(ubyte*) hash_table)[0 .. allocatedSize];
        allocator.free(bytes);
        hash_table = null;
        hash_table_power = 0;
        elements = 0;
    }

    void check_hash_table()
    {
        int new_hash_table_power = -1;

        if (cast(int) elements > ((1 << hash_table_power) * RELATIONSHIP))
        {
            /* rehash up */
            new_hash_table_power = hash_table_power + 1;

            while (cast(int) elements > ((1 << new_hash_table_power) * RELATIONSHIP))
            {
                new_hash_table_power++;
            }

        }
        else if ((hash_table_power > cast(int) MIN_HASH_TABLE_POWER) && (
                cast(int) elements < ((1 << (hash_table_power - 1)) * RELATIONSHIP)))
        {
            /* rehash down */
            new_hash_table_power = hash_table_power - 1;

            while (cast(int) elements < ((1 << (new_hash_table_power - 1)) * RELATIONSHIP))
            {
                new_hash_table_power--;
            }

            if (new_hash_table_power < cast(int) MIN_HASH_TABLE_POWER)
            {
                new_hash_table_power = MIN_HASH_TABLE_POWER;
            }
        }

        if (new_hash_table_power == -1)
        {
            return;
        }

        //Element **new_hash_table = memnew_arr(Element*, (cast(ulong)1 << new_hash_table_power));
        auto newSize = (Element*).sizeof * (cast(size_t) 1 << new_hash_table_power);
        Element** new_hash_table = cast(Element**) allocator.raw_alloc(newSize).ptr;
        //ERR_FAIL_COND_MSG(!new_hash_table, "Out of memory.");

        for (int i = 0; i < (1 << new_hash_table_power); i++)
        {
            new_hash_table[i] = null;
        }

        if (hash_table)
        {
            for (int i = 0; i < (1 << hash_table_power); i++)
            {
                while (hash_table[i])
                {
                    Element* se = hash_table[i];
                    hash_table[i] = se.next;
                    int new_pos = se.hash & ((1 << new_hash_table_power) - 1);
                    se.next = new_hash_table[new_pos];
                    new_hash_table[new_pos] = se;
                }
            }
            //memdelete_arr(hash_table);
            
            auto bytes = (cast(ubyte*) hash_table)[0 .. allocatedSize];
            allocator.free(bytes);
        }
        hash_table = new_hash_table;
        allocatedSize = newSize;
        hash_table_power = cast(ubyte) new_hash_table_power;
    }

    const Element* get_element(const ref Key p_key)
    {

        if (!hash_table)
            return null;
        uint hash = hash(p_key);
        uint index = hash & ((1 << hash_table_power) - 1);

        Element* e = cast(Element*) hash_table[index];

        while (e)
        {
            /* checking hash first avoids comparing key, which may take longer */
            if (e.hash == hash && compare(e.pair.key, p_key))
            {
                /* the pair exists in this hashtable, so just update data */
                return e;
            }
            e = e.next;
        }

        return null;
    }

    Element* create_element(const ref Key p_key)
    {
        /* if element doesn't exist, create it */
        Element* e = cast(Element*) allocator.raw_alloc(Element.sizeof).ptr;
        //ERR_FAIL_COND_V_MSG(!e, nullptr, "Out of memory.");
        uint hash = hash(p_key);
        uint index = hash & ((1 << hash_table_power) - 1);
        e.next = hash_table[index];
        e.hash = hash;
        e.pair.key = cast(Key)p_key; // TODO: when i use pointer as key, i need this
        //e.pair.value = ;

        hash_table[index] = e;
        elements++;
        return e;
    }

    public:
    Element* set(const ref Key key, const ref Value value)
    {
        Element* e = null;
        if (!hash_table)
        {
            make_hash_table(); // if no table, make one
        }
        else
        {
            e = cast(Element*)(get_element(key));
        }

        /* if we made it up to here, the pair doesn't exist, create and assign */

        if (!e)
        {
            e = create_element(key);
            if (!e)
            {
                return null;
            }
            check_hash_table(); // perform mantenience routine
        }

        e.pair.value = cast(Value) value;
        return e;
    }

    ref Value get(const ref Key p_key)
    {
        Value* res = getptr(p_key);
        //CRASH_COND_MSG(!res, "Map key not found.");
        return *res;
    }

    Value* getptr(const ref Key p_key)
    {
        if (!hash_table)
        {
            return null;
        }

        Element* e = cast(Element*)(get_element(p_key));

        if (e)
        {
            return &e.pair.value;
        }

        return null;
    }

    bool erase(const ref Key p_key)
    {
        if (!hash_table)
        {
            return false;
        }

        uint hash = hash(p_key);
        uint index = hash & ((1 << hash_table_power) - 1);

        Element* e = hash_table[index];
        Element* p = null;
        while (e)
        {
            /* checking hash first avoids comparing key, which may take longer */
            if (e.hash == hash && compare(e.pair.key, p_key))
            {
                if (p)
                {
                    p.next = e.next;
                }
                else
                {
                    //begin of list
                    hash_table[index] = e.next;
                }

                allocator.destroy(e);
                elements--;

                if (elements == 0)
                {
                    erase_hash_table();
                }
                else
                {
                    check_hash_table();
                }
                return true;
            }

            p = e;
            e = e.next;
        }

        return false;
    }

    bool remove(const ref Key key)
    {
        return erase(key);
    }

    bool has(const ref Key p_key)
    {
        return getptr(p_key) != null;
    }

    uint count() const {
        return elements;
    }

    bool is_empty() const {
        return elements == 0;
    }

    void clear()
    {
        /* clean up */
        if (hash_table) {
            for (int i = 0; i < (1 << hash_table_power); i++) {
                while (hash_table[i]) {
                    Element *e = hash_table[i];
                    hash_table[i] = e.next;
                    allocator.destroy(e);
                }
            }

            auto bytes = (cast(ubyte*) hash_table)[0 .. allocatedSize];
            allocator.free(bytes);
        }

        hash_table = null;
        hash_table_power = 0;
        elements = 0;
    }

    int opApply(int delegate(Pair*) dg)
    {
        if(!hash_table) return 0;

        int result;
        for (int i = 0; i < (1 << hash_table_power); i++) {
            Element* e = hash_table[i];
            while(e) {
                if ((result = dg(&e.pair)) != 0)
                    break;
                e = e.next;
            }
        }
        return result;
    }

    int opApply(int delegate(Key, Value) dg)
    {
        if(!hash_table) return 0;

        int result;
        for (int i = 0; i < (1 << hash_table_power); i++) {
            Element* e = hash_table[i];
            while(e) {
                if ((result = dg(e.pair.key, e.pair.value)) != 0)
                    break;
                e = e.next;
            }
        }
        return result;
    }

    void opIndexAssign(const ref Value value, const ref Key key) {
        set(key, value);
    }

    // TODO: how to handle error
    ref Value opIndex(const ref Key key) {
        if(!has(key)) panic("key not found");
        return get(key);
    }

}

private:

uint hash(T)(inout ref T v)
{
    static if(is(T == U*, U) && __traits(isScalar, T)) 
    {
        return hash_one_uint64(cast(ulong) v);
    }
    else static if( is(T == int) || is(T == uint)) 
    {
        return hash_one_uint64(cast(ulong) v);
    }
    else static if( is(T == short) || is(T == ushort)) 
    {
        return hash_one_uint64(cast(ulong) v);
    }
    else static if( is(T == long) || is(T == ulong) ) 
    {
        return hash_one_uint64(cast(ulong) v);
    }
    else static if( is(T == float) || is(T == double) ) 
    {
        return hash_djb2_one_float(v);
    }
    else static if ( is (T == string) )
    {
        return cast(int) string_hash(v);
    }
    else static if ( is (T == const(char)[]) )
    {
        return cast(int) string_hash(v);
    }
    else {
        static assert(0, "not supported: " ~ T.stringof);
    }
}

bool compare(T)(inout ref T p_lhs, inout ref T p_rhs)
{
    static if(is(T == U*, U) && __traits(isScalar, T)) 
    {
        return p_lhs == p_rhs;
    }
    else static if( is(T == int) || is(T == uint)) 
    {
        return p_lhs == p_rhs;
    }
    else static if( is(T == short) || is(T == ushort)) 
    {
        return p_lhs == p_rhs;
    }
    else static if( is(T == long) || is(T == ulong)) 
    {
        return p_lhs == p_rhs;
    }
    else static if( is(T == float) || is(T == double) ) 
    {
        return (p_lhs == p_rhs) || (is_nan(p_lhs) && is_nan(p_rhs));
    } 
    else static if ( is (T == string) )
    {
        //auto len = p_lhs.length;
        //auto same = !strncmp(p_lhs.ptr, p_rhs.ptr, len);
        //return same;
        return (p_lhs == p_rhs);
    }
    else static if ( is (T == const(char)[]) )
    {
        auto len = strlen(p_lhs.ptr);
        auto same = !strncmp(p_lhs.ptr, p_rhs.ptr, len);
        return same;
        // return (p_lhs == p_rhs);
    }
    else {
        static assert(0, "not supported " ~ T.stringof);
    }
}

ulong string_hash(const(char)[] name)
{
    import h= rt.hash;
    return h.hash_fast(cast(ubyte[]) name);

    //size_t length = name.length;
    //ulong hash = 0xcbf29ce484222325;
    //ulong prime = 0x00000100000001b3;

    //for (size_t i = 0; i < length; i++)
    //{
    //    ubyte value = name[i];
    //    hash = hash ^ value;
    //    hash *= prime;
    //}
    //return hash;
}
ulong slice_hash(const(char)[] name)
{
    import h= rt.hash;
    return h.hash_fast(cast(ubyte[]) name);
}

uint hash_djb2(const(char)* p_cstr)
{
    const(ubyte)* chr = cast(const(ubyte)*) p_cstr;
    uint hash = 5381;
    uint c;

    while ((c = *chr++) == 1)
    { // TODO: check == 1
        hash = ((hash << 5) + hash) + c; /* hash * 33 + c */
    }

    return hash;
}

ulong hash_djb2_one_float_64(double p_in, ulong p_prev = 5381)
{
    union U
    {
        double d;
        ulong i;
    }

    U u;

    // Normalize +/- 0.0 and NaN values so they hash the same.
    if (p_in == 0.0f)
    {
        u.d = 0.0;
    }
    else if (is_nan(p_in))
    {
        u.d = float.nan;
    }
    else
    {
        u.d = p_in;
    }

    return ((p_prev << 5) + p_prev) + u.i;
}

ulong hash_djb2_one_64(ulong p_in, ulong p_prev = 5381)
{
    return ((p_prev << 5) + p_prev) + p_in;
}

uint hash_one_uint64(const ulong p_int)
{
    ulong v = p_int;
    v = (~v) + (v << 18); // v = (v << 18) - v - 1;
    v = v ^ (v >> 31);
    v = v * 21; // v = (v + (v << 2)) + (v << 4);
    v = v ^ (v >> 11);
    v = v + (v << 6);
    v = v ^ (v >> 22);
    return cast(int) v;
}

uint hash_djb2_one_float(double p_in, uint p_prev = 5381)
{
    union U
    {
        double d;
        ulong i;
    }

    U u;

    // Normalize +/- 0.0 and NaN values so they hash the same.
    if (p_in == 0.0f)
    {
        u.d = 0.0;
    }
    else if (is_nan(p_in))
    {
        u.d = float.nan;
    }
    else
    {
        u.d = p_in;
    }

    return ((p_prev << 5) + p_prev) + hash_one_uint64(u.i);
}


size_t strlen(const char* txt)
{
    size_t l = 0;
    while(txt[l] != '\0')
        l++;
    return l;
}
int strncmp(const char* _l, const char* _r, size_t n)
{
    ubyte* l = cast(ubyte*) cast(void*) _l;
    ubyte* r = cast(ubyte*) cast(void*) _r;
    if (!n--)
        return 0;
    for (; *l && *r && n && *l == *r; l++, r++, n--)
    {
    }
    return *l - *r;
}

bool is_nan(X)(X x) if (__traits(isFloating, X))
{
    version (all)
    {
        return x != x;
    }
    else
    {
        panic("not supported");
    }
}



size_t pow2ceil(size_t num) {
    size_t power = 1;
    while (power < num) {
        power *= 2;
    }
    return power;
}

//struct HashMapBUGGY(K, V, alias hashfn = hash!(K), alias eqfn = compare!(K))
//{
//    struct Entry {
//        K key;
//        V val;
//        bool filled;
//    }

//    Entry[] entries;
//    size_t cap;
//    size_t len;
//    Allocator allocator;

//    void create(Allocator alloc, size_t caphint = 32) {
        
//        allocator = alloc;
//        len = 0;
//        cap = pow2ceil(caphint);
//        entries = alloc.alloc!(Entry)(cap);
//        for(int i = 0; i < entries.length; i++)
//        {
//            entries[i] = Entry.init;
//        }
//    }

//    void dispose() {
//        assert(allocator.vt);
//        assert(entries.ptr);
//        allocator.free(entries);
//    }

//    void clear()
//    {
//        len = 0;
//        for(int i = 0; i < entries.length; i++)
//        {
//            entries[i] = Entry.init;
//        }
//    }

//    V get(K key) {
//        return get(key, null);
//    }

//    V get(K key, bool* found = null) {
//        ulong hash = hashfn(key);
//        size_t idx = hash & (this.cap - 1);

//        while (this.entries[idx].filled) {
//            if (eqfn(this.entries[idx].key, key)) {
//                if (found) *found = true;
//                return this.entries[idx].val;
//            }
//            idx++;
//            if (idx >= this.cap) {
//                idx = 0;
//            }
//        }
//        if (found) *found = false;

//        V val;
//        return val;
//    }
    
//    V* get_ptr(K key) {
//        ulong hash = hashfn(key);
//        size_t idx = hash & (this.cap - 1);

//        while (this.entries[idx].filled) {
//            if (eqfn(this.entries[idx].key, key)) {
//                return &this.entries[idx].val;
//            }
//            idx++;
//            if (idx >= this.cap) {
//                idx = 0;
//            }
//        }
//        return null;
//    }
    
//    bool has(K key) {
//        assert(entries.ptr);
//        ulong hash = hashfn(key);
//        size_t idx = hash & (this.cap - 1);
//        while (this.entries[idx].filled) {
//            if (eqfn(this.entries[idx].key, key)) {
//                return true;
//            }
//            idx++;
//            if (idx >= this.cap) {
//                idx = 0;
//            }
//        }
//        return false;
//    }

//    private bool resize(size_t newcap) {
//        Entry[] entries = allocator.alloc!(Entry)(newcap);
//        if (!entries.ptr) {
//            return false;
//        }

//        HashMap newmap = {
//            entries: entries,
//            cap: newcap,
//            len: this.len,
//            allocator: allocator,
//        };

//        for (size_t i = 0; i < this.cap; i++) {
//            Entry ent = this.entries[i];
//            if (ent.filled) {
//                newmap.put(ent.key, ent.val);
//            }
//        }

//        allocator.free(this.entries);

//        this.cap = newmap.cap;
//        this.entries = newmap.entries;

//        return true;
//    }

//    // TODO: FIXME: sometimes stuck in the while loop, perhaps full need resizing?
//    bool put(K key, V val) {
//        if (this.len >= this.cap / 2) {
//            bool ok = resize(this.cap * 2);
//            if (!ok) {
//                return false;
//            }
//        }

//        ulong hash = hashfn(key);
//        size_t idx = hash & (this.cap - 1);

//        while (this.entries[idx].filled) {
//            if (eqfn(this.entries[idx].key, key)) {
//                this.entries[idx].val = val;
//                return true;
//            }
//            idx++;
//            if (idx >= this.cap) {
//                idx = 0;
//            }
//        }

//        this.entries[idx].key = key;
//        this.entries[idx].val = val;
//        this.entries[idx].filled = true;
//        this.len++;

//        return true;
//    }

//    void set(K key, V val)
//    {
//        put(key, val);
//    }

//    private void rmidx(size_t idx) {
//        this.entries[idx].filled = false;
//        this.len--;
//    }

//    bool remove(K key) {
//        ulong hash = hashfn(key);
//        size_t idx = hash & (this.cap - 1);

//        while (this.entries[idx].filled && !eqfn(this.entries[idx].key, key)) {
//            idx = (idx + 1) & (this.cap - 1);
//        }

//        if (!this.entries[idx].filled) {
//            return true;
//        }

//        rmidx(idx);

//        idx = (idx + 1) & (this.cap - 1);

//        while (this.entries[idx].filled) {
//            K krehash = this.entries[idx].key;
//            V vrehash = this.entries[idx].val;
//            rmidx(idx);
//            put(krehash, vrehash);
//            idx = (idx + 1) & (this.cap - 1);
//        }

//        // halves the array if it is 12.5% full or less
//        if (this.len > 0 && this.len <= this.cap / 8) {
//            return resize(this.cap / 2);
//        }
//        return true;
//    }

//    int opApply(int delegate(ref K, ref V) dg)
//    {
//        assert(entries.ptr);
//        int result;
//        for (int i = 0; i < entries.length; i++) {
//            auto e = &entries[i];
//            if (e.filled == false) continue;
//            if ((result = dg(e.key, e.val)) != 0)
//                    break;
//        }
//        return result;
//    }

//    void opIndexAssign(V value, K key) {
//        put(key, value);
//    }

//    // TODO: how to handle error
//    V opIndex(K key) {
//        if(!has(key)) panic("key not found");
//        return get(key);
//    }

//}

//struct HashMapFCK(Key, Value, Hasher = HashFunc!(Key), Comparer = HashComp!(Key))
//{
//    import rt.container.array;
//    struct Pair
//    {
//        Key key;
//        Value value;
//        uint hash;
//    }

//    Allocator allocator;
//    Array!Pair table;
//    size_t count;

//    void create(Allocator alloc, int capacity = 16)
//    {
//        allocator = alloc;
//        table.create(alloc, capacity);
//    }

//    bool get(Key key, Value* value)
//    {
//        uint hash = HashFunc.hash(key);
//        foreach(size_t i, Pair p; table)
//        {
//            if (p.hash == hash && HashComp.compare(p.key, key))
//            {
//                value = &p.value;
//                return true;
//            }
//            if(p.hash > hash) break;
//        }
//        return false;
//    }

    
//    bool has(Key key)
//    {
//        uint hash = HashFunc.hash(key);
//        foreach(size_t i, Pair p; table)
//        {
//            if (p.hash == hash && HashComp.compare(p.key, key))
//            {
//                return true;
//            }
//            if(p.hash > hash) break;
//        }
//        return false;
//    }

//    Value* get_ptr(Key key)
//    {
//        uint hash = HashFunc.hash(key);
//        foreach(size_t i, Pair p; table)
//        {
//            if (p.hash == hash && HashComp.compare(p.key, key))
//            {
//                return &p.value;
//            }
//            if(p.hash > hash) break;
//        }
//        return null;
//    }

//    void set(Key key, Value value)
//    {
//        uint hash = HashFunc.hash(key);

//        foreach(size_t i, Pair* p; table)
//        {
//            if(p.hash == hash && HashComp.compare(p.key, key))
//            {
//                p.value = value;
//                return;
//            }
            
//            if(p.hash > hash)
//            {
//                table.insert(i, Pair(key, value, hash));
//                count++;
//                return;
//            }
//        }
//        table.add(Pair(key, value, hash));
//        count++;
//    }

//    void remove(Key key)
//    {
//        uint hash = HashFunc.hash(key);

//        foreach(size_t i, Pair p; table)
//        {
//            if(p.hash == hash && HashComp.compare(p.key, key))
//            {
//                table.remove_at(i);
//                count--;
//                return;
//            }
            
//            if(p.hash > hash)
//                break;
//        }
//    }

//    void clear()
//    {
//        table.clear();
//        count = 0;
//    }

    
//    void opIndexAssign(Value value, Key key) {
//        set(key, value);
//    }

//    // TODO: how to handle error
//    Value* opIndex(Key key) {
//        if(!has(key)) panic("key not found");
//        return get_ptr(key);
//    }

//}

