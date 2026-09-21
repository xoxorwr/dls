module rt.container.queue;

import rt.memz;


struct Queue(T)
{
    uint size = 0;
    uint max_size = 0;
    T* items = null;
    uint head = 0;
    uint tail = 0;
    Allocator allocator;

    void create(Allocator allocator, int maxSize = 16)
    {
        this.allocator = allocator;
        max_size = maxSize;
        items = cast(T*) allocator.alloc(T.sizeof * maxSize);
    }

    void dispose()
    {
        allocator.free(items[0 .. T.sizeof * max_size]);
    }

    T* push()
    {
        assert(this.size < this.max_size);
        T* new_slot = this.items + this.tail;
        if (this.tail + 1 >= this.max_size)
        {
            this.tail = 0;
        }
        else
        {
            this.tail++;
        }
        this.size++;
        return new_slot;
    }

    T push(T new_item)
    {
        T* new_slot = push();
        *new_slot = new_item;
        return new_item;
    }

    T* pop()
    {
        assert(this.size > 0);
        T* item = this.items + this.head;
        if (this.head + 1 >= this.max_size)
        {
            this.head = 0;
        }
        else
        {
            this.head++;
        }
        this.size--;
        return item;
    }
}