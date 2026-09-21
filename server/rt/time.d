module rt.time;

import rt.dbg;

version (WebAssembly)
{
    import rt.wasm;
}

long get_unix_time()
{
    version (WebAssembly)
    {
        return cast(long) js_get_time();
    }
    else
    {
        import core.stdc.time : time;
        return cast(long) time(null);
    }
}


long get_time()
{
    version (WebAssembly) return js_get_time();
    else return cast(long) now().msecs();
}

ulong ticks()
{
    version (Windows)
    {
        import core.sys.windows.windows : QueryPerformanceCounter;
        import core.sys.windows.windows : LARGE_INTEGER;

        LARGE_INTEGER counter;
        QueryPerformanceCounter(&counter);
        return counter.QuadPart;
    }
    else version (Posix)
    {
        import core.sys.posix.time : clock_gettime;
        import core.sys.posix.time : timespec;
        import core.sys.posix.time : CLOCK_MONOTONIC;

        timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);

        ulong ticks = 0;
        ticks += now.tv_sec;
        ticks *= 1_000_000_000;
        ticks += now.tv_nsec;
        return ticks;
    }
    else
    {
        import rt.wasm;
        return cast(ulong)(js_ticks() * 1_000_000.0);
    }
}

ulong frequency()
{
    version (Windows)
    {
        import core.sys.windows.windows : QueryPerformanceFrequency;
        import core.sys.windows.windows : LARGE_INTEGER;

        LARGE_INTEGER frequency;
        QueryPerformanceFrequency(&frequency);
        return frequency.QuadPart;
    }
    else version (Posix)
    {
        return 1_000_000_000;
    }
    else
    {
        return 1_000_000_000;
    }
}

struct StopWatch
{
    ulong start_ticks = 0;
    ulong stop_ticks = 0;

    void reset()
    {
        start_ticks = 0;
        stop_ticks = 0;
    }

    void restart()
    {
        reset();
        start();
    }

    bool is_running()
    {
        return start_ticks != 0;
    }

    bool is_stopped()
    {
        return stop_ticks != 0;
    }

    void start()
    {
        start_ticks = ticks();
    }

    void stop()
    {
        stop_ticks = ticks();
    }

    void resume()
    {
        start_ticks += ticks() - stop_ticks;
    }

    Timespan elapsed()
    {
        if (is_running() == false) return Timespan(0, frequency());

        auto t = (is_stopped() ? stop_ticks : ticks()) - start_ticks;
        return Timespan(t, frequency());
    }
}

struct Timespan
{
    ulong ticks;
    ulong frequency;

    double nano()
    {
        return ((ticks * 1000.0) / frequency) * 1_000_000.0;
    }
	double usecs()
	{
	    return cast(double)ticks * 1_000_000.0 / frequency;
	}
    double msecs()
    {
        return cast(double)ticks * 1000.0 / frequency;
    }

    long msecs_i()
    {
        return cast(long) (cast(double)ticks * 1000.0 / frequency);
    }

    double seconds()
    {
        return cast(double)ticks / frequency;
    }

    Timespan opBinary(string op : "-")(Timespan other)
    {
        return Timespan(ticks - other.ticks, frequency);
    }
}

Timespan now()
{
    return Timespan(ticks(), frequency());
}
