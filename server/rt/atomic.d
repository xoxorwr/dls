module rt.atomic;

int cas (uint* val, uint expected, uint desired)
{
    version (X86_64)
    {
        asm
        {
            // RDI is val_ptr
            // ESI is expected
            // EDX is desired
            naked;
            mov EAX, ESI;
            lock; cmpxchg int ptr [RDI], EDX;
            ret ;
        }
    }
    else version (X86)
    {
        // TODO for some reason dmd1 -m32 bloats this function with nops
        asm
        {
            naked ;
            mov EDX, dword ptr [ESP+4];  // EDX is val_ptr
            mov EAX, dword ptr [ESP+8];  // EAX is expected
            mov ECX, dword ptr [ESP+12]; // ECX is desired
            lock; cmpxchg dword ptr [EDX], ECX;
            ret ;
            db 0x0f, 0x1f, 0x00; // 3byte nop
        }
    }
    else
    {
        import core.atomic : atomicLoad, cas;

        // druntime's CAS only reports whether the store happened.
        auto target = cast(shared(uint)*) val;
        uint current = atomicLoad(*target);
        while (current == expected && !cas(target, expected, desired))
            current = atomicLoad(*target);
        return cast(int) current;
    }
}

int cas (int* val, int expected, int desired)
{
    version (X86_64)
    {
        version(Windows)
        {
        asm
        {
            // RDI is val_ptr
            // ESI is expected
            // EDX is desired
            naked;
            mov EAX, ESI;
            lock; cmpxchg int ptr [RDI], EDX;
            ret ;
        }
        }
        else
        {
          asm {
              mov EDX, expected;
              mov EAX, desired;
              mov RCX, val;
              lock; // lock always needed to make this op atomic
              cmpxchg [RCX], EDX;
          }
        }
    }
    else version (X86)
    {
        // TODO for some reason dmd1 -m32 bloats this function with nops
        asm
        {
            naked ;
            mov EDX, dword ptr [ESP+4];  // EDX is val_ptr
            mov EAX, dword ptr [ESP+8];  // EAX is expected
            mov ECX, dword ptr [ESP+12]; // ECX is desired
            lock; cmpxchg dword ptr [EDX], ECX;
            ret ;
            db 0x0f, 0x1f, 0x00; // 3byte nop
        }
    }
    else
    {
        import core.atomic : atomicLoad, cas;

        auto target = cast(shared(int)*) val;
        int current = atomicLoad(*target);
        while (current == expected && !cas(target, expected, desired))
            current = atomicLoad(*target);
        return current;
    }
}

void increment(ulong* reference)
{
    version (X86_64)
    {
        asm
        {
            naked;
            lock;
            inc long ptr [RDI];
            ret;
        }
    }
    else
        atomicAdd(reference, 1);
}

void increment(uint* reference)
{
    version (X86_64)
    {
        asm
        {
            naked;
            lock;
            inc int ptr [RDI];
            ret;
        }
    }
    else
        atomicAdd(reference, 1);
}
void increment(int* reference)
{
    version (X86_64)
    {
        asm
        {
            naked;
            lock;
            inc int ptr [RDI];
            ret;
        }
    }
    else
        atomicAdd(reference, 1);
}

void decrement(ulong* reference)
{
    version (X86_64)
    {
        asm
        {
            naked;
            lock;
            dec long ptr [RDI];
            ret;
        }
    }
    else
        atomicSub(reference, 1);
}

void decrement(uint* reference)
{
    version (X86_64)
    {
        asm
        {
            naked;
            lock;
            dec int ptr [RDI];
            ret;
        }
    }
    else
        atomicSub(reference, 1);
}
void decrement(int* reference)
{
    version (X86_64)
    {
        asm
        {
            naked;
            lock;
            dec int ptr [RDI];
            ret;
        }
    }
    else
        atomicSub(reference, 1);
}

void add(ulong* reference, ulong value)
{
    version (X86_64)
    {
        asm
        {
            naked;
            lock;
            xadd [RDI], RSI;
            ret;
        }
    }
    else
        atomicAdd(reference, value);
}

void add(uint* reference, uint value)
{
    version (X86_64)
    {
        asm
        {
            naked;
            lock;
            xadd [RDI], RSI;
            ret;
        }
    }
    else
        atomicAdd(reference, value);
}

private void atomicAdd(T)(T* reference, size_t value)
{
    import core.atomic : atomicFetchAdd;
    atomicFetchAdd(*reference, value);
}

private void atomicSub(T)(T* reference, size_t value)
{
    import core.atomic : atomicFetchSub;
    atomicFetchSub(*reference, value);
}

/*
// move to its own module
pragma(LDC_intrinsic, "ldc.bitop.vld") ubyte volatileLoad(ubyte* ptr);
pragma(LDC_intrinsic, "ldc.bitop.vld") ushort volatileLoad(ushort* ptr);
pragma(LDC_intrinsic, "ldc.bitop.vld") uint volatileLoad(uint* ptr);
pragma(LDC_intrinsic, "ldc.bitop.vld") ulong volatileLoad(ulong* ptr);
pragma(LDC_intrinsic, "ldc.bitop.vst") void volatileStore(ubyte* ptr, ubyte value);
pragma(LDC_intrinsic, "ldc.bitop.vst") void volatileStore(ushort* ptr, ushort value);
pragma(LDC_intrinsic, "ldc.bitop.vst") void volatileStore(uint* ptr, uint value);
pragma(LDC_intrinsic, "ldc.bitop.vst") void volatileStore(ulong* ptr, ulong value);
*/
