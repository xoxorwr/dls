module rt.crash_handler.linux;

import core.stdc.stdlib;
import core.stdc.string;
import core.stdc.stdio;
import core.sys.posix.unistd;
import core.sys.posix.signal;
import core.sys.posix.stdio;
import core.sys.posix.ucontext;
import core.sys.linux.execinfo;
import core.sys.linux.dlfcn;
import core.sys.linux.link;

version(X86_64)      enum REG_IP = 16;
else version(X86)    enum REG_IP = 14;
else version(ARM)    enum REG_IP = 15;

extern(C) export void rt_register_crash_handler()
{
    sigaction_t sa;
    sa.sa_sigaction = &handler;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);

    sigaction(SIGSEGV, &sa, null);
    sigaction(SIGILL,  &sa, null);
    sigaction(SIGABRT, &sa, null);
    sigaction(SIGFPE,  &sa, null);
}

extern (C):
private:
enum MAX_DEPTH = 32;

void handler(int sig, siginfo_t* info, void* context)
{
    ucontext_t* uc = cast(ucontext_t*)context;
    size_t faulting_ip;
	version(AArch64) {
        faulting_ip = cast(size_t)uc.uc_mcontext.pc;
    } else {
        faulting_ip = cast(size_t)uc.uc_mcontext.gregs[REG_IP];
    }

    fprintf(stderr, "\r\ncrash: signal %d\r\n", sig);
    print_bt(faulting_ip);
    exit(-1);
}

public void print_bt(size_t faulting_ip = 0)
{
    fprintf(stderr, "stacktrace:\n");
    void*[MAX_DEPTH] trace;
    int stack_depth = backtrace(&trace[0], MAX_DEPTH);

    char[1024] syscom;
    char[1024] path;

    bool found_crash_site = false;

    for (int i = 0; i < stack_depth; ++i)
    {
        size_t current_pc = cast(size_t)trace[i];
        if (!found_crash_site) {
            if (current_pc == faulting_ip) found_crash_site = true;
            else continue;
        }

        size_t vma_addr;
        Dl_info info;
        link_map* lmap = convert_to_vma(current_pc, faulting_ip, &vma_addr, &info);

        if (!lmap || !info.dli_fname) continue;

        sprintf(syscom.ptr, "addr2line -e '%s' -p -i -C %p 2>/dev/null",
                info.dli_fname, cast(void*)vma_addr);

        FILE* fp = popen(syscom.ptr, "r");
        if (fp) {
            if (fgets(path.ptr, path.length, fp)) {
                if (path[0] == '?' && current_pc != faulting_ip) {
                    pclose(fp);
                    continue;
                }
                fprintf(stderr, "  %s", path.ptr);
            }
            pclose(fp);
        }
    }
    fprintf(stderr, "\r\n");
}

link_map* convert_to_vma(size_t addr, size_t faulting_ip, size_t* converted, Dl_info* info)
{
    link_map* lmap;
    if (dladdr1(cast(void*) addr, info, cast(void**)&lmap, RTLD_DL_LINKMAP) == 0)
        return null;

    size_t rel = addr - lmap.l_addr;

    if (addr == faulting_ip) {
        *converted = rel;
    } else {
        *converted = rel - 1;
    }

    return lmap;
}
