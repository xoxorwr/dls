module rt.container.array;

import rt.memz;
import rt.dbg;

struct Array(T)
{
    T[] items;
    Allocator allocator;
    size_t count = 0;

    size_t capacity()
    {
        return items.length;
    }

    size_t length()
    {
        return count;
    }

    bool empty()
    {
        return count == 0;
    }

    static Array createWith(Allocator allocator, size_t capacity = 16)
    {
        Array ret;
        ret.allocator = allocator;
        ret.count = 0;
        ret.items = allocator.alloc!(T)(capacity);
        return ret;
    }

    void create(Allocator allocator, size_t capacity = 16)
    {
        this.allocator = allocator;
        this.count = 0;
        items = allocator.alloc!(T)(capacity);
    }

    void dispose()
    {
        allocator.free(items);
    }

    void fill(T value)
    {
        for(int i = 0; i < count; i++)
        {
            items[i] = value;
        }
    }

    void fill_default()
    {
        for(int i = 0; i < count; i++)
        {
            items[i] = T.init;
        }
    }

    //inout(T)[] opIndex() inout => _storage[0 .. _length];

    ref T opIndex(size_t index)
    {
        if ((index < 0) || (index >= count))
            panic("out of bound");
        return items[index];
    }

    void opIndexAssign(T value, in size_t index)
    {
        if (index >= count)
            panic("out of bound");
        items[index] = value;
    }

    // foreach
    int opApply(int delegate(T*) dg)
    {
        int result;
        //foreach (ref T item; items)
        for (int i = 0; i < count; i++)
            if ((result = dg(&items[i])) != 0)
                break;
        return result;
    }
    int opApply(int delegate(ref T) dg)
    {
        int result;
        //foreach (ref T item; items)
        for (int i = 0; i < count; i++)
            if ((result = dg(items[i])) != 0)
                break;
        return result;
    }

    int opApply(int delegate(size_t, ref T) dg)
    {
        int result;
        //foreach (ref T item; items)
        for (size_t i = 0; i < count; i++)
            if ((result = dg(i, items[i])) != 0)
                break;
        return result;
    }

    int opApply(int delegate(size_t, T*) dg)
    {
        int result;
        //foreach (ref T item; items)
        for (size_t i = 0; i < count; i++)
            if ((result = dg(i, &items[i])) != 0)
                break;
        return result;
    }

    // --

    T get(size_t index)
    {
        if ((index < 0) || (index >= count))
            panic("out of bound");
        return items[index];
    }


    T* get_ptr(int index)
    {
        if ((index < 0) || (index >= count))
            panic("out of bound");
        return &items[index];
    }

    void set(size_t index, ref T value)
    {
        if (index >= count)
            panic("out of bound");
        items[index] = value;
    }

    void ensureTotalCapacity(size_t new_capacity)
    {
        auto capacity = items.length;

        size_t better_capacity = capacity;
        if (better_capacity >= new_capacity) return;

        while (true) {
            better_capacity += better_capacity / 2 + 8;
            if (better_capacity >= new_capacity) break;
        }

        size_t originalLength = capacity;
        size_t diff = new_capacity - capacity;

        // TODO This can be optimized to avoid needlessly copying undefined memory.
        // T* new_memory = cast(T*) allocator.reallocate(items, better_capacity * T.sizeof);

        // items = new_memory;
        // capacity = better_capacity;

        // if (diff > 0)
        // {
        //     // todo: fill stuff with default values
        //     for (size_t i = originalLength; i < originalLength + diff; i++)
        //     {
        //         items[i] = T.init;
        //     }
        // }

        auto newm = allocator.alloc!(T)(better_capacity);
        memcpy(newm.ptr, items.ptr, capacity * T.sizeof);

        allocator.free(items);

        capacity = better_capacity;
        items = newm;

        if (diff > 0)
        {
            for (size_t i = originalLength; i < originalLength + diff; i++)
            {
                items[i] = T.init;
            }
        }
    }


    void reserve(size_t newCap)
    {
        ensureTotalCapacity(newCap); // TODO: test
    }

    void expandToCapacity()
    {
        count = items.length;
    }

    void resize(size_t newSize)
    {
        ensureTotalCapacity(cast(int)newSize);
        count = cast(int) newSize;
    }

    void clear()
    {
        for (int i = 0; i < count; i++)
        {
            items[i] = T.init;
        }

        count = 0;
    }

    T* add_get(T item)
    {
        auto length = capacity;
        if (count + 1 > length)
        {
            // auto expand = (length < 1000) ? (length + 1) * 4 : 1000;
            auto expand = (length + 1) * 1.2;
            ensureTotalCapacity(length + cast(int)expand);
        }

        auto pos = count;
        items[count++] = item;
        return &items[pos];
    }

    void add(T item)
    {
        auto length = items.length;
        if (count + 1 > length)
        {
            // auto expand = (length < 1000) ? (length + 1) * 4 : 1000;
            auto expand = (length + 1) * 1.2;
            ensureTotalCapacity(length + cast(int)expand);
        }

        items[count++] = item;
    }

    T* add_get_one()
    {
        auto length = items.length;
        if (count + 1 > length)
        {
            // auto expand = (length < 1000) ? (length + 1) * 4 : 1000;
            auto expand = (length + 1) * 4;

            ensureTotalCapacity(length + expand);
        }

        return &items[count++];
    }

    void add_all(ref Array!T items)
    {
        // todo: optimize, should be a memcpy
        for (int i = 0; i < items.length(); i++)
            add(items[i]);
    }

    void insert(size_t index, T item)
    {
        assert(index < count);

        auto capacity = items.length;
        if (count == capacity)
        {
            ensureTotalCapacity(max(8, cast(size_t)(capacity * 1.75f)));
        }

        // System.arraycopy(items, index, items, index + 1, size - index);
        memcpy(items.ptr, items.ptr + 1, count - index); // TODO: test this
        count++;
        items[index] = item;
    }

    void ensureUnusedCapacity(size_t additionalcount) {
        ensureTotalCapacity(capacity() + additionalcount);
    }

    bool remove(T item)
    {
        for (int i = 0; i < count; i++)
        {
            // static if ( is(T == float[]))
            // {
            //     static assert(0, "ffff");
            // }

            if (items[i] == item)
            {
                return remove_at(i);
            }
        }
        return false;
    }


    // TODO: add tests for both of them
    T removeSwap(size_t index)
    {
        if (length - 1 == index) return pop_ret();

         auto old_item = items[index];
         items[index] = pop_ret();
         return old_item;
    }

    void pop()
    {
        count -= 1;
    }

    T pop_ret()
    {
        auto val = items[length - 1];
        count -= 1;
        return val;
    }

    int index_of(T item)
    {
        for (int i = 0; i < count; i++)
            if (items[i] == item)
                return i;
        return -1;
    }

    bool contains(T item)
    {
        for (int i = 0; i < count; i++)
            if (items[i] == item)
                return true;
        return false;
    }

    bool remove_at(size_t index)
    {
        T val = items[index];
        count--;

        static if (__traits(isPOD, T))
        {
            memmove(items.ptr + index, // dest
                    items.ptr + index + 1, // src
                    (count - index) * T.sizeof); // num bytes
        }
        else
        {
            for (auto j = index; j < count; j++)
            {
                items[j] = items[j + 1];
            }
        }
        return true;
    }

    bool remove_back()
    {
        return remove_at(count - 1);
    }

    T[] get_slice()
    {
        return items[0 .. count];
    }

    ref T back()
    {
        assert(count > 0);
        return items[count - 1];
    }
}

struct Arr(T, int CAPACITY)
{
    int count = 0;
    T[CAPACITY] items;

    int length() { return count;}

    void dispose(){}

    bool empty()
    {
        return count == 0;
    }

    int opApply(scope int delegate(ref T) dg)
    {
        int result;
        //foreach (ref T item; items)
        for (int i = 0; i < count; i++)
            if ((result = dg(items[i])) != 0)
                break;
        return result;
    }

    int opApply(scope int delegate(T*) dg)
    {
        int result;
        //foreach (ref T item; items)
        for (int i = 0; i < count; i++)
            if ((result = dg(&items[i])) != 0)
                break;
        return result;
    }

    int opApply(scope int delegate(int, T*) dg)
    {
        int result;
        //foreach (ref T item; items)
        for (int i = 0; i < count; i++)
            if ((result = dg(i, &items[i])) != 0)
                break;
        return result;
    }

    ref T opIndex(int index)
    {
        if ((index < 0) || (index >= count))
            panic("out of bound");
        return items[index];
    }

    void opIndexAssign(T value, in int index)
    {
        if (index >= count)
            panic("out of bound");
        items[index] = value;
    }

    ref T get(int index)
    {
        if ((index < 0) || (index >= count))
            panic("out of bound");
        return items[index];
    }

    void set(int index, ref T value)
    {
        if (index >= count)
            panic("out of bound");
        items[index] = value;
    }

    void add(T item, string f = __FILE__, int l = __LINE__)
    {
        auto c = count;
        auto len = items.length;
        if (c >= len)
            panic("full: {} {}", f, l);
        items[count++] = item;
    }

    bool remove_at(size_t index)
    {
        T val = items[index];
        count--;

        static if (__traits(isPOD, T))
        {
            memmove(items.ptr + index, // dest
                    items.ptr + index + 1, // src
                    (count - index) * T.sizeof); // num bytes
        }
        else
        {
            for (auto j = index; j < count; j++)
            {
                items[j] = items[j + 1];
            }
        }
        return true;
    }

    bool remove(const ref T item)
    {
        for (int i = 0; i < count; i++)
        {
            if (items[i] == item)
            {
                return remove_at(i);
            }
        }
        return false;
    }

    T back()
    {
        if(count == 0) panic("empty");
        return items[count - 1];
    }

    T* back_ptr()
    {
        if(count == 0) panic("empty");
        return &items[count - 1];
    }

    T* ptr()
    {
        return items.ptr;
    }

    T[] get_slice()
    {
        return items[0 .. count];
    }
}

package:

size_t max(size_t a, size_t b)
{
    return a < b ? b : a;
}