module rt.args;

import rt.dbg;
import str = rt.str;
import mem = rt.memz;

alias cb_t = void function(const(char)[]);

struct Option
{
    const(char)[] key;
    cb_t cb;
}

void parse(char[][] arg, scope const Option[] options)
{
    for(int i = 0; i < arg.length; i++)
    {
        for (int j = 0; j < options.length; j++)
        {
            auto aa = arg[i];
            if(mem.equals(aa, options[j].key))
            {
                if (i+1 == arg.length)
                {
                    options[j].cb(null);
                    break;
                }
                auto next = arg[i+1];
                auto nn = cast(char[]) next;

                if (mem.starts_with("-", nn) == false)
                {
                    options[j].cb(nn);
                }
                else 
                    options[j].cb(null);
            }
        }
    }
}
void parse(int argc, char**argv, scope const Option[] options)
{
    for(int i = 0; i < argc; i++)
    {
        import str = rt.str;
        auto a = argv[i];
        auto alen = str.str_len(a);
        auto aa = a[0 .. alen];

        for (int j = 0; j < options.length; j++)
        {
            import rt.dbg;
            if(mem.equals(aa, options[j].key))
            {
                if (i+1 == argc)
                {
                    options[j].cb(null);
                    break;
                }
                auto next = argv[i+1];
                auto nextLen = str.str_len(next);
                auto nn = next[0 .. nextLen];

                if (mem.starts_with("-", nn) == false)
                {
                    options[j].cb(nn);
                }
                else 
                    options[j].cb(null);
            }
        }
    }
}