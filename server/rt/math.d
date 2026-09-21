module rt.math;

import rt.dbg;

enum float FLOAT_ROUNDING_ERROR = 0.000001f;
enum float PI = 3.14159265358979323846; 
enum float PI2 = PI * 2; // TAU
enum float PIDIV2 = PI / 2;
enum float DEG2RAD = PI / 180.0f;
enum float RAD2DEG = 180.0f / PI;

enum isFloatingPoint(T) = __traits(isFloating, T) && is(T : real);


double ldexp(double x, int n)
{
    return scalbn(x, n);
}

double scalbn(double x, int n)
{
    union _TEMP {double f; ulong i;} _TEMP u;
    double y = x;

    if (n > 1023) {
        y *= 0x1p1023;
        n -= 1023;
        if (n > 1023) {
            y *= 0x1p1023;
            n -= 1023;
            if (n > 1023)
                n = 1023;
        }
    } else if (n < -1022) {
        /* make sure final n < -53 to avoid double
           rounding in the subnormal range */
        y *= 0x1p-1022 * 0x1p53;
        n += 1022 - 53;
        if (n < -1022) {
            y *= 0x1p-1022 * 0x1p53;
            n += 1022 - 53;
            if (n < -1022)
                n = -1022;
        }
    }
    u.i = cast(ulong)(0x3ff+n)<<52;
    x = y * u.f;
    return x;
}


bool is_zero(float value)
{
  return abs(value) <= FLOAT_ROUNDING_ERROR;
}

float normalize(double val, double valmin, double valmax, double min, double max) 
{
    return (((val - valmin) / (valmax - valmin)) * (max - min)) + min;
}

bool is_pow_2(int i)
{
    assert(i >= 0);
    return (i != 0) && ((i & (i - 1)) == 0);
}

int next_pow2(int n) {
	if (n <= 0) {
		return 0;
	}
	n--;
	n |= n >> 1;
	n |= n >> 2;
	n |= n >> 4;
	n |= n >> 8;
	n |= n >> 16;
	n++;
	return n;
}

long next_pow2(long n) {
	if (n <= 0) {
		return 0;
	}
	n--;
	n |= n >> 1;
	n |= n >> 2;
	n |= n >> 4;
	n |= n >> 8;
	n |= n >> 16;
	n |= n >> 32;
	n++;
	return n;
}

//isize next_pow2_isize(isize n) {
//	if (n <= 0) {
//		return 0;
//	}
//	n--;
//	n |= n >> 1;
//	n |= n >> 2;
//	n |= n >> 4;
//	n |= n >> 8;
//	n |= n >> 16;

//	version(X86_64)
//		n |= n >> 32;
//	n++;
//	return n;
//}

uint next_pow2_u32(uint n) {
	if (n == 0) {
		return 0;
	}
	n--;
	n |= n >> 1;
	n |= n >> 2;
	n |= n >> 4;
	n |= n >> 8;
	n |= n >> 16;
	n++;
	return n;
}


int bit_set_count(uint x) {
	x -= ((x >> 1) & 0x55555555);
	x = (((x >> 2) & 0x33333333) + (x & 0x33333333));
	x = (((x >> 4) + x) & 0x0f0f0f0f);
	x += (x >> 8);
	x += (x >> 16);

	return cast(int)(x & 0x0000003f);
}

long bit_set_count(ulong x) {
	uint a = *(cast(uint *)&x);
	uint b = *(cast(uint *)&x + 1);
	return bit_set_count(a) + bit_set_count(b);
}


version (WebAssembly)
{
    extern(C):
    pragma(LDC_intrinsic, "llvm.sqrt.f32")
    float sqrt(float value);
    pragma(LDC_intrinsic, "llvm.cos.f32")
    float cosf(float value);
    pragma(LDC_intrinsic, "llvm.sin.f32")
    float sinf(float value);

    float acosf(float value);
    float tanf(float value);
    float absf(float value);

    float logf(float value);
    float roundf(float value);
    float atan2f(float y, float x);
    double pow(double x, double y);
}
else
{
    import cmath = core.stdc.math;
    // import ccmath = core.math;

    float acosf(float value)
    {
        return cmath.acosf(value);
    }

    float sqrt(float value)
    {
        return cmath.sqrt(value);
    }

    float sinf(float value)
    {
        return cmath.sin(value);
    }

    float cosf(float value)
    {
        return cmath.cos(value);
    }

    float tanf(float value)
    {
        return cmath.tanf(value);
    }

    float atan2f(float y, float x)
    {
        return cmath.atan2f(y, x);
    }

    float absf(float value)
    {
        return cmath.fabs(value);
    }

    float roundf(float value)
    {
        return cmath.roundf(value);
    }

    float logf(float value)
    {
        return cmath.log(value);
    }

    double pow(double x, double y)
    {
        return cmath.pow(x, y);
    }

    double ceil(double v)
    {
        return cmath.ceil(v);
    }
}

float dst(float x1, float y1, float x2, float y2)
{
    float x_d = x2 - x1;
    float y_d = y2 - y1;
    return sqrt(x_d * x_d + y_d * y_d);
}

F min(F)(F x, F y) if (__traits(isFloating, F))
{
    if (isNaN(x))
        return y;
    return y < x ? y : x;
}

F min(F)(F x, F y) if (__traits(isIntegral, F))
{
    return y < x ? y : x;
}

T max(T, U)(T a, U b)
if (is(T == U) && is(typeof(a < b)))
{
   /* Handle the common case without all the template expansions
    * of the general case
    */
    return a < b ? b : a;
}

auto abs(Num)(Num x)
if ((is(immutable Num == immutable short) || is(immutable Num == immutable byte)) ||
    (is(typeof(Num.init >= 0)) && is(typeof(-Num.init))))
{
    static if (isFloatingPoint!(Num))
        return absf(x);
    else
    {
        static if (is(immutable Num == immutable short) || is(immutable Num == immutable byte))
            return x >= 0 ? x : cast(Num) -int(x);
        else
            return x >= 0 ? x : -x;
    }
}



struct vec2
{
    float x = 0f;
    float y = 0f;

    this(float x, float y)
    {
        this.x = x;
        this.y = y;
    }

    pragma(inline)
    {
        vec2 opBinary(string op)(vec2 other)
        {
            vec2 ret;
            mixin("ret.x = x" ~ op ~ "other.x;");
            mixin("ret.y = y" ~ op ~ "other.y;");
            return ret;
        }

        vec2 opOpAssign(string op)(vec2 other)
        {
            // TODO: test
            static if (op == "+")
            {
                x += other.x;
                y += other.y;
                return this;
            }
            else static if (op == "-")
            {
                x -= other.x;
                y -= other.y;
                return this;
            }
            else static if (op == "*")
            {
                x *= other.x;
                y *= other.y;
                return this;
            }
            else static if (op == "/")
            {
                x /= other.x;
                y /= other.y;
                return this;
            }
            else
                static assert(0, "Operator " ~ op ~ " not implemented");
        }

        vec2 opBinary(string op)(float other)
        {

            vec2 ret;
            mixin("ret.x = x" ~ op ~ "other;");
            mixin("ret.y = y" ~ op ~ "other;");
            return ret;
        }

        float len()
        {
            return cast(float) sqrt(x * x + y * y);
        }

        void nor()
        {
            float l = len();
            if (l != 0)
            {
                x /= l;
                y /= l;
            }
        }

        vec2 point_at(float distance, float angle) {
            vec2 ret;
            ret.x = this.x + distance* cosf(angle);
            ret.y = this.y + distance* sinf(angle);
            return ret;
        }


        static vec2 normalize(vec2 other)
        {
            float l = other.len();
            if (l != 0)
            {
                vec2 ret;
                ret.x = other.x / l;
                ret.y = other.y / l;
                return ret;
            }
            return other;
        }

        static vec2 normalize(float x, float y)
        {
            vec2 ret = vec2(x, y);
            float l = ret.len();
            if (l != 0)
            {
                ret.x = x / l;
                ret.y = y / l;
            }
            return ret;
        }

        static vec2 local_to_world(vec2 p, vec2 translation, float rotation)
        {
            vec2 v;

            // Apply rotation
            float sin = sinf(rotation);
            float cos = cosf(rotation);

            v.x = p.x * cos - p.y * sin;
            v.y = p.x * sin + p.y * cos;

            // Apply translation
            return v + translation;
        }

    }
}

struct vec3
{
    float x = 0f;
    float y = 0f;
    float z = 0f;

    enum vec3 UNIT_X = vec3(1,0,0);
    enum vec3 UNIT_Y = vec3(0,1,0);
    enum vec3 UNIT_Z = vec3(0,0,1);
    enum vec3 ZERO =  vec3(0,0,0);

    this(float v)
    {
        x = y = z = v;
    }

    this(float x, float y, float z)
    {
        this.x = x;
        this.y = y;
        this.z = z;
    }

    
    pragma(inline)
    static vec3 set(float x, float y, float z)
    {
        return vec3(x, y, z);
    }

    pragma(inline)
    float len2()
    {
        return x * x + y * y + z * z;
    }

    pragma(inline)
    vec3 nor()
    {
        float l = len2();
        if (l == 0f || l == 1f)
            return vec3(x, y, z);

        float scalar = 1f / sqrt(l);

        return vec3(x * scalar, y * scalar, z * scalar);
    }

    pragma(inline)
    float dot(vec3 vector)
    {
        return x * vector.x + y * vector.y + z * vector.z;
    }
    
    pragma(inline)
    static float dot(vec3 left, vec3 right)
    {
        return left.x * right.x + left.y * right.y + left.z * right.z;
    }

    pragma(inline)
    vec3 crs(vec3 vector)
    {
        return vec3(y * vector.z - z * vector.y, z * vector.x - x * vector.z,
                x * vector.y - y * vector.x);
    }

    pragma(inline)
    vec3 mul(ref mat4 m)
    {
        return vec3(x * m.m00 + y * m.m01 + z * m.m02 + m.m03,
                x * m.m10 + y * m.m11 + z * m.m12 + m.m13, x * m.m20 + y * m.m21 + z * m.m22 + m
                .m23);
    }

    pragma(inline)
    vec3 mul(mat4* m)
    {
        return vec3(x * m.m00 + y * m.m01 + z * m.m02 + m.m03,
                x * m.m10 + y * m.m11 + z * m.m12 + m.m13, x * m.m20 + y * m.m21 + z * m.m22 + m
                .m23);
    }

    pragma(inline)
    void prj(mat4 matrix)
    {
        auto l_w = 1f / (x * matrix.m30 + y * matrix.m31 + z * matrix.m32 + matrix.m33);

        auto cpy_x = (x * matrix.m00 + y * matrix.m01 + z * matrix.m02 + matrix.m03) * l_w;
        auto cpy_y = (x * matrix.m10 + y * matrix.m11 + z * matrix.m12 + matrix.m13) * l_w;
        auto cpy_z = (x * matrix.m20 + y * matrix.m21 + z * matrix.m22 + matrix.m23) * l_w;

        this.x = cpy_x;
        this.y = cpy_y;
        this.z = cpy_z;
    }

    pragma(inline)
    float dst2(ref vec3 other)
    {
        float a = other.x - x;
		float b = other.y - y;
		float c = other.z - z;
		return a * a + b * b + c * c;
    }

    pragma(inline)
    bool is_zero()
    {
        return x == 0 && y == 0 && z == 0;
    }

    pragma(inline)
    vec3 opUnary(string s)() if (s == "-")
    {
        return vec3(-x, -y, -z);
    }

    pragma(inline)
    vec3 opBinary(string op)(vec3 other)
    {
        vec3 ret = void;
        mixin("ret.x = x" ~ op ~ "other.x;");
        mixin("ret.y = y" ~ op ~ "other.y;");
        mixin("ret.z = z" ~ op ~ "other.z;");
        return ret;
    }

    pragma(inline)
    vec3 opOpAssign(string op)(vec3 other)
    {
        static if (op == "+")
        {
            x += other.x;
            y += other.y;
            z += other.z;
        }
        else static if (op == "-")
        {
            x -= other.x;
            y -= other.y;
            z -= other.z;
        }
        else static if (op == "*")
        {
            x *= other.x;
            y *= other.y;
            z *= other.z;
        }
        else static if (op == "/")
        {
            x /= other.x;
            y /= other.y;
            z /= other.z;
        }
        return this;
    }

    vec3 opBinary(string op)(float other)
    {
        vec3 ret;
        mixin("ret.x = x" ~ op ~ "other;");
        mixin("ret.y = y" ~ op ~ "other;");
        mixin("ret.z = z" ~ op ~ "other;");
        return ret;
    }

    pragma(inline)
    static float len(float x, float y, float z)
    {
        return sqrt(x * x + y * y + z * z);
    }

    pragma(inline)
    static vec3 lerp(const ref vec3 lhs, const ref vec3 rhs, float t)
    {
        if (t > 1f)
        {
            return rhs;
        }
        else
        {
            if (t < 0f)
            {
                return lhs;
            }
        }
        vec3 res;
        res.x = (rhs.x - lhs.x) * t + lhs.x;
        res.y = (rhs.y - lhs.y) * t + lhs.y;
        res.z = (rhs.z - lhs.z) * t + lhs.z;
        return res;
    }

    pragma(inline)
    static float dot(const ref vec3 lhs, const ref vec3 rhs)
    {
        return lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z;
    }

    pragma(inline)
    static vec3 cross(const ref vec3 lhs, const ref vec3 rhs)
    {
        vec3 res;
        res.x = lhs.y * rhs.z - lhs.z * rhs.y;
        res.y = lhs.z * rhs.x - lhs.x * rhs.z;
        res.z = lhs.x * rhs.y - lhs.y * rhs.x;
        return res;
    }

    pragma(inline)
    static vec3 rotate(const ref vec3 lhs, const ref vec3 axis, float angle)
    {
        auto rotation = quat.from_axis(axis, angle);
        auto matrix = mat4.set(0, 0, 0, rotation.x, rotation.y, rotation.z, rotation.w);

        return transform(lhs, matrix);
    }

    pragma(inline)
    static vec3 transform(const ref vec3 lhs, const ref mat4 matrix)
    {
        float inv_w = 1.0f / (lhs.x * matrix.m30 + lhs.y * matrix.m31 + lhs.z
                * matrix.m32 + matrix.m33);
        vec3 ret;
        ret.x = (lhs.x * matrix.m00 + lhs.y * matrix.m01 + lhs.z * matrix.m02 + matrix.m03) * inv_w;
        ret.y = (lhs.x * matrix.m10 + lhs.y * matrix.m11 + lhs.z * matrix.m12 + matrix.m13) * inv_w;
        ret.z = (lhs.x * matrix.m20 + lhs.y * matrix.m21 + lhs.z * matrix.m22 + matrix.m23) * inv_w;
        return ret;
    }
}

struct mat4
{
    enum M00 = 0;
    enum M01 = 4;
    enum M02 = 8;
    enum M03 = 12;
    enum M10 = 1;
    enum M11 = 5;
    enum M12 = 9;
    enum M13 = 13;
    enum M20 = 2;
    enum M21 = 6;
    enum M22 = 10;
    enum M23 = 14;
    enum M30 = 3;
    enum M31 = 7;
    enum M32 = 11;
    enum M33 = 15;

    union
    {
        struct
        {
            float m00 = 0;
            float m10 = 0;
            float m20 = 0;
            float m30 = 0;
            float m01 = 0;
            float m11 = 0;
            float m21 = 0;
            float m31 = 0;
            float m02 = 0;
            float m12 = 0;
            float m22 = 0;
            float m32 = 0;
            float m03 = 0;
            float m13 = 0;
            float m23 = 0;
            float m33 = 0;
        }
        float[4][4] m = void;
        quat[4]	col = void;
        float[16] all = void;
    }

    this(float m00, float m01, float m02, float m03, float m04, float m05,
            float m06, float m07, float m08, float m09, float m10, float m11,
            float m12, float m13, float m14, float m15)
    {
        this.m00 = m00;
        this.m10 = m01;
        m20 = m02;
        m30 = m03;
        this.m01 = m04;
        this.m11 = m05;
        m21 = m06;
        m31 = m07;
        this.m02 = m08;
        this.m12 = m09;
        m22 = m10;
        m32 = m11;
        this.m03 = m12;
        this.m13 = m13;
        m23 = m14;
        m33 = m15;
    }

    pragma(inline)
    {
        static mat4 identity()
        {
            mat4 ret = void;
            ret.m00 = 1f;
            ret.m01 = 0f;
            ret.m02 = 0f;
            ret.m03 = 0f;

            ret.m10 = 0f;
            ret.m11 = 1f;
            ret.m12 = 0f;
            ret.m13 = 0f;

            ret.m20 = 0f;
            ret.m21 = 0f;
            ret.m22 = 1f;
            ret.m23 = 0f;

            ret.m30 = 0f;
            ret.m31 = 0f;
            ret.m32 = 0f;
            ret.m33 = 1f;
            return ret;
        }

        mat4 idt()
        {
            m00 = 1f;
            m01 = 0f;
            m02 = 0f;
            m03 = 0f;
            m10 = 0f;
            m11 = 1f;
            m12 = 0f;
            m13 = 0f;
            m20 = 0f;
            m21 = 0f;
            m22 = 1f;
            m23 = 0f;
            m30 = 0f;
            m31 = 0f;
            m32 = 0f;
            m33 = 1f;
            return this;
        }

        static mat4 inv(ref mat4 m)
        {
            float	m00 = m.col[0].x;
            float	m10 = m.col[0].y;
            float	m20 = m.col[0].z;
            float	m30 = m.col[0].w;

            float	m01 = m.col[1].x;
            float	m11 = m.col[1].y;
            float	m21 = m.col[1].z;
            float	m31 = m.col[1].w;

            float	m02 = m.col[2].x;
            float	m12 = m.col[2].y;
            float	m22 = m.col[2].z;
            float	m32 = m.col[2].w;

            float	m03 = m.col[3].x;
            float	m13 = m.col[3].y;
            float	m23 = m.col[3].z;
            float	m33 = m.col[3].w;

            float	denom	= (m03 * m12 * m21 * m30 - m02 * m13 * m21 * m30 -
                       m03 * m11 * m22 * m30 + m01 * m13 * m22 * m30 +
                       m02 * m11 * m23 * m30 - m01 * m12 * m23 * m30 -
                       m03 * m12 * m20 * m31 + m02 * m13 * m20 * m31 +
                       m03 * m10 * m22 * m31 - m00 * m13 * m22 * m31 -
                       m02 * m10 * m23 * m31 + m00 * m12 * m23 * m31 +
                       m03 * m11 * m20 * m32 - m01 * m13 * m20 * m32 -
                       m03 * m10 * m21 * m32 + m00 * m13 * m21 * m32 +
                       m01 * m10 * m23 * m32 - m00 * m11 * m23 * m32 -
                       m02 * m11 * m20 * m33 + m01 * m12 * m20 * m33 +
                       m02 * m10 * m21 * m33 - m00 * m12 * m21 * m33 -
                       m01 * m10 * m22 * m33 + m00 * m11 * m22 * m33);
            float	inv_det = 1.0f / denom;

            float	r00 = (m12 * m23 * m31 - m13 * m22 * m31 +
                       m13 * m21 * m32 - m11 * m23 * m32 -
                       m12 * m21 * m33 + m11 * m22 * m33) * inv_det;

            float	r01 = (m03 * m22 * m31 - m02 * m23 * m31 -
                       m03 * m21 * m32 + m01 * m23 * m32 +
                       m02 * m21 * m33 - m01 * m22 * m33) * inv_det;

            float	r02 = (m02 * m13 * m31 - m03 * m12 * m31 +
                       m03 * m11 * m32 - m01 * m13 * m32 -
                       m02 * m11 * m33 + m01 * m12 * m33) * inv_det;

            float	r03 = (m03 * m12 * m21 - m02 * m13 * m21 -
                       m03 * m11 * m22 + m01 * m13 * m22 +
                       m02 * m11 * m23 - m01 * m12 * m23) * inv_det;

            float	r10 = (m13 * m22 * m30 - m12 * m23 * m30 -
                       m13 * m20 * m32 + m10 * m23 * m32 +
                       m12 * m20 * m33 - m10 * m22 * m33) * inv_det;

            float	r11 = (m02 * m23 * m30 - m03 * m22 * m30 +
                       m03 * m20 * m32 - m00 * m23 * m32 -
                       m02 * m20 * m33 + m00 * m22 * m33) * inv_det;

            float	r12 = (m03 * m12 * m30 - m02 * m13 * m30 -
                       m03 * m10 * m32 + m00 * m13 * m32 +
                       m02 * m10 * m33 - m00 * m12 * m33) * inv_det;

            float	r13 = (m02 * m13 * m20 - m03 * m12 * m20 +
                       m03 * m10 * m22 - m00 * m13 * m22 -
                       m02 * m10 * m23 + m00 * m12 * m23) * inv_det;

            float	r20 = (m11 * m23 * m30 - m13 * m21 * m30 +
                       m13 * m20 * m31 - m10 * m23 * m31 -
                       m11 * m20 * m33 + m10 * m21 * m33) * inv_det;

            float	r21 = (m03 * m21 * m30 - m01 * m23 * m30 -
                       m03 * m20 * m31 + m00 * m23 * m31 +
                       m01 * m20 * m33 - m00 * m21 * m33) * inv_det;

            float	r22 = (m01 * m13 * m30 - m03 * m11 * m30 +
                       m03 * m10 * m31 - m00 * m13 * m31 -
                       m01 * m10 * m33 + m00 * m11 * m33) * inv_det;

            float	r23 = (m03 * m11 * m20 - m01 * m13 * m20 -
                       m03 * m10 * m21 + m00 * m13 * m21 +
                       m01 * m10 * m23 - m00 * m11 * m23) * inv_det;

            float	r30 = (m12 * m21 * m30 - m11 * m22 * m30 -
                       m12 * m20 * m31 + m10 * m22 * m31 +
                       m11 * m20 * m32 - m10 * m21 * m32) * inv_det;

            float	r31 = (m01 * m22 * m30 - m02 * m21 * m30 +
                       m02 * m20 * m31 - m00 * m22 * m31 -
                       m01 * m20 * m32 + m00 * m21 * m32) * inv_det;

            float	r32 = (m02 * m11 * m30 - m01 * m12 * m30 -
                       m02 * m10 * m31 + m00 * m12 * m31 +
                       m01 * m10 * m32 - m00 * m11 * m32) * inv_det;

            float	r33 = (m01 * m12 * m20 - m02 * m11 * m20 +
                       m02 * m10 * m21 - m00 * m12 * m21 -
                       m01 * m10 * m22 + m00 * m11 * m22) * inv_det;

            return mat4(r00, r10, r20, r30,
                    r01, r11, r21, r31,
                    r02, r12, r22, r32,
                    r03, r13, r23, r33);
        }

        pragma(inline, true)
        float det3x3()
        {
            return m00 * m11 * m22 + m01 * m12 * m20 + m02 * m10 * m21 - m00 * m12 * m21
                - m01 * m10 * m22 - m02 * m11 * m20;
        }

        pragma(inline, true)
        vec3 get_translation()
        {        
    	    vec3 position = void;
    	    position.x = m03;
    	    position.y = m13;
    	    position.z = m23;
    	    return position;
        }

        pragma(inline, true)        
        bool has_rot_or_scl () {
            return !(m00 == 1 && m11 == 1 &&  m22 == 1
                     &&  m01 == 0 
                     &&  m02 == 0 
                     &&  m10 == 0 
                     &&  m12 == 0
                     &&  m20 == 0 
                     &&  m21 == 0);
        }
    }
    static mat4 create_orthographic_offcenter(float x, float y, float width, float height)
    {
        return create_orthographic(x, x + width, y, y + height, 0, 1);
    }

    static mat4 create_orthographic(float left, float right, float bottom,
            float top, float near = 0f, float far = 1f)
    {
        mat4 ret = void;

        float x_orth = 2 / (right - left);
        float y_orth = 2 / (top - bottom);
        float z_orth = -2 / (far - near);

        float tx = -(right + left) / (right - left);
        float ty = -(top + bottom) / (top - bottom);
        float tz = -(far + near) / (far - near);

        ret.m00 = x_orth;
        ret.m10 = 0;
        ret.m20 = 0;
        ret.m30 = 0;
        ret.m01 = 0;
        ret.m11 = y_orth;
        ret.m21 = 0;
        ret.m31 = 0;
        ret.m02 = 0;
        ret.m12 = 0;
        ret.m22 = z_orth;
        ret.m32 = 0;
        ret.m03 = tx;
        ret.m13 = ty;
        ret.m23 = tz;
        ret.m33 = 1;

        return ret;
    }

    static mat4 create_look_at(vec3 eye, vec3 dest, vec3 up)
    {
        vec3	f	= (dest - eye).nor();
        vec3	s	= vec3.cross(f, up).nor();
        vec3	u	= vec3.cross(s, f).nor();

        mat4	trans	= mat4.create_translation(-eye);

        mat4	m	= mat4(s.x, u.x, -f.x, 0.0f,
                       s.y, u.y, -f.y, 0.0f,
                       s.z, u.z, -f.z, 0.0f,
                       0.0f, 0.0f, 0.0f, 1.0f);
        //LWARN("f: {}:{}:{}", f.x, f.y, f.z);
        //LWARN("s: {}:{}:{}", s.x, s.y, s.z);
        //LWARN("u: {}:{}:{}", u.x, u.y, u.z);
        //LWARN("up: {}:{}:{}", up.x, up.y, up.z);
        //LWARN("eye: {}:{}:{}", eye.x, eye.y, eye.z);

        
        //for (int i = 0; i < 16; i++)
        //{
        //    LINFO("trans: {}", trans.all[i]);
        //}
        
        //for (int i = 0; i < 16; i++)
        //{
        //    LINFO("m: {}", m.all[i]);
        //}
        return m * trans;
    }

    pragma(inline)
    static mat4 create_translation(vec3 trs)
    {
         return mat4(
            1.0f, 0.0f, 0.0f, 0.0f,
            0.0f, 1.0f, 0.0f, 0.0f,
            0.0f, 0.0f, 1.0f, 0.0f,
            trs.x, trs.y, trs.z, 1.0f
        );
    }

    pragma(inline)
    static mat4 create_rotation(quat q)
    {
        float	xx = q.x * q.x;
        float	xy = q.x * q.y;
        float	xz = q.x * q.z;
        float	xw = q.x * q.w;
        float	yy = q.y * q.y;
        float	yz = q.y * q.z;
        float	yw = q.y * q.w;
        float	zz = q.z * q.z;
        float	zw = q.z * q.w;

        float	m00 = 1.0f - 2.0f * (yy + zz);
        float	m01 = 2.0f * (xy - zw);
        float	m02 = 2.0f * (xz + yw);
        float	m10 = 2.0f * (xy + zw);
        float	m11 = 1.0f - 2.0f * (xx + zz);
        float	m12 = 2.0f * (yz - xw);
        float	m20 = 2.0f * (xz - yw);
        float	m21 = 2.0f * (yz + xw);
        float	m22 = 1.0f - 2.0f * (xx + yy);

        return mat4(m00, m10, m20, 0.0f,
                m01, m11, m21, 0.0f,
                m02, m12, m22, 0.0f,
                0.0f, 0.0f, 0.0f, 1.0f);
    }

    pragma(inline)
    static mat4 create_scale(vec3 scale)
    {
        return mat4(scale.x, 0.0f, 0.0f, 0.0f,
        0.0f, scale.y, 0.0f, 0.0f,
        0.0f, 0.0f, scale.z, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f);
    }

    pragma(inline)
    static mat4 create_projection(float near, float far, float fovy, float aspectRatio)
    {
        mat4 ret = void;
        float l_fd = cast(float)(1.0 / tanf((fovy * (PI / 180)) / 2.0));
        float l_a1 = (far + near) / (near - far);
        float l_a2 = (2 * far * near) / (near - far);
        //LINFO("l_fd: {}", l_fd);
        //LINFO("l_a1: {}", l_a1);
        //LINFO("l_a2: {}", l_a2);
        ret.m00 = l_fd / aspectRatio;
        ret.m10 = 0;
        ret.m20 = 0;
        ret.m30 = 0;
        ret.m01 = 0;
        ret.m11 = l_fd;
        ret.m21 = 0;
        ret.m31 = 0;
        ret.m02 = 0;
        ret.m12 = 0;
        ret.m22 = l_a1;
        ret.m32 = -1;
        ret.m03 = 0;
        ret.m13 = 0;
        ret.m23 = l_a2;
        ret.m33 = 0;
        return ret;
    }

    pragma(inline)
    static mat4 create_look_at(vec3 direction, vec3 up)
    {
        auto l_vez = direction.nor();
        auto l_vex = direction.nor();

        l_vex = l_vex.crs(up).nor();
        auto l_vey = l_vex.crs(l_vez).nor();

        auto ret = mat4.identity();
        ret.m00 = l_vex.x;
        ret.m01 = l_vex.y;
        ret.m02 = l_vex.z;
        ret.m10 = l_vey.x;
        ret.m11 = l_vey.y;
        ret.m12 = l_vey.z;
        ret.m20 = -l_vez.x;
        ret.m21 = -l_vez.y;
        ret.m22 = -l_vez.z;

        return ret;
    }

    pragma(inline)
    static mat4 set(float translationX, float translationY, float translationZ, float quaternionX, float quaternionY, float quaternionZ, float quaternionW)
    {
        float xs = quaternionX * 2.0f, ys = quaternionY * 2.0f, zs = quaternionZ * 2.0f;
        float wx = quaternionW * xs, wy = quaternionW * ys, wz = quaternionW * zs;
        float xx = quaternionX * xs, xy = quaternionX * ys, xz = quaternionX * zs;
        float yy = quaternionY * ys, yz = quaternionY * zs, zz = quaternionZ * zs;

        mat4 ret;
        ret.m00 = (1.0f - (yy + zz));
        ret.m01 = (xy - wz);
        ret.m02 = (xz + wy);
        ret.m03 = translationX;

        ret.m10 = (xy + wz);
        ret.m11 = (1.0f - (xx + zz));
        ret.m12 = (yz - wx);
        ret.m13 = translationY;

        ret.m20 = (xz - wy);
        ret.m21 = (yz + wx);
        ret.m22 = (1.0f - (xx + yy));
        ret.m23 = translationZ;

        ret.m30 = 0.0f;
        ret.m31 = 0.0f;
        ret.m32 = 0.0f;
        ret.m33 = 1.0f;
        return ret;
    }

    pragma(inline)
    static mat4 set(ref vec3 translation, ref quat rotation)
    {
        float xs = rotation.x * 2.0f, ys = rotation.y * 2.0f, zs = rotation.z * 2.0f;
        float wx = rotation.w * xs, wy = rotation.w * ys, wz = rotation.w * zs;
        float xx = rotation.x * xs, xy = rotation.x * ys, xz = rotation.x * zs;
        float yy = rotation.y * ys, yz = rotation.y * zs, zz = rotation.z * zs;

        mat4 ret = void;
        ret.m00 = (1.0f - (yy + zz));
        ret.m01 = (xy - wz);
        ret.m02 = (xz + wy);
        ret.m03 = translation.x;

        ret.m10 = (xy + wz);
        ret.m11 = (1.0f - (xx + zz));
        ret.m12 = (yz - wx);
        ret.m13 = translation.y;

        ret.m20 = (xz - wy);
        ret.m21 = (yz + wx);
        ret.m22 = (1.0f - (xx + yy));
        ret.m23 = translation.z;

        ret.m30 = 0.0f;
        ret.m31 = 0.0f;
        ret.m32 = 0.0f;
        ret.m33 = 1.0f;
        return ret;
    }

    pragma(inline)
    static mat4 set(ref vec3 translation, ref quat rotation, ref vec3 scale)
    {
        float xs = rotation.x * 2.0f, ys = rotation.y * 2.0f, zs = rotation.z * 2.0f;
        float wx = rotation.w * xs, wy = rotation.w * ys, wz = rotation.w * zs;
        float xx = rotation.x * xs, xy = rotation.x * ys, xz = rotation.x * zs;
        float yy = rotation.y * ys, yz = rotation.y * zs, zz = rotation.z * zs;

        mat4 ret = void;
        ret.m00 = scale.x * (1.0f - (yy + zz));
        ret.m01 = scale.y * (xy - wz);
        ret.m02 = scale.z * (xz + wy);
        ret.m03 = translation.x;

        ret.m10 = scale.x * (xy + wz);
        ret.m11 = scale.y * (1.0f - (xx + zz));
        ret.m12 = scale.z * (yz - wx);
        ret.m13 = translation.y;

        ret.m20 = scale.x * (xz - wy);
        ret.m21 = scale.y * (yz + wx);
        ret.m22 = scale.z * (1.0f - (xx + yy));
        ret.m23 = translation.z;

        ret.m30 = 0.0f;
        ret.m31 = 0.0f;
        ret.m32 = 0.0f;
        ret.m33 = 1.0f;
        return ret;
    }

    pragma(inline)
    static mat4 mult(ref mat4 lhs, ref mat4 rhs)
    {
        return mat4(lhs.m00 * rhs.m00 + lhs.m01 * rhs.m10 + lhs.m02 * rhs.m20 + lhs.m03 * rhs.m30,
                lhs.m10 * rhs.m00 + lhs.m11 * rhs.m10 + lhs.m12 * rhs.m20 + lhs.m13 * rhs.m30,
                lhs.m20 * rhs.m00 + lhs.m21 * rhs.m10 + lhs.m22 * rhs.m20 + lhs.m23 * rhs.m30,
                lhs.m30 * rhs.m00 + lhs.m31 * rhs.m10 + lhs.m32 * rhs.m20 + lhs.m33 * rhs.m30,

                lhs.m00 * rhs.m01 + lhs.m01 * rhs.m11 + lhs.m02 * rhs.m21 + lhs.m03 * rhs.m31,
                lhs.m10 * rhs.m01 + lhs.m11 * rhs.m11 + lhs.m12 * rhs.m21 + lhs.m13 * rhs.m31,
                lhs.m20 * rhs.m01 + lhs.m21 * rhs.m11 + lhs.m22 * rhs.m21 + lhs.m23 * rhs.m31,
                lhs.m30 * rhs.m01 + lhs.m31 * rhs.m11 + lhs.m32 * rhs.m21 + lhs.m33 * rhs.m31,

                lhs.m00 * rhs.m02 + lhs.m01 * rhs.m12 + lhs.m02 * rhs.m22 + lhs.m03 * rhs.m32,
                lhs.m10 * rhs.m02 + lhs.m11 * rhs.m12 + lhs.m12 * rhs.m22 + lhs.m13 * rhs.m32,
                lhs.m20 * rhs.m02 + lhs.m21 * rhs.m12 + lhs.m22 * rhs.m22 + lhs.m23 * rhs.m32,
                lhs.m30 * rhs.m02 + lhs.m31 * rhs.m12 + lhs.m32 * rhs.m22 + lhs.m33 * rhs.m32,

                lhs.m00 * rhs.m03 + lhs.m01 * rhs.m13 + lhs.m02 * rhs.m23 + lhs.m03 * rhs.m33,
                lhs.m10 * rhs.m03 + lhs.m11 * rhs.m13 + lhs.m12 * rhs.m23 + lhs.m13 * rhs.m33,
                lhs.m20 * rhs.m03 + lhs.m21 * rhs.m13 + lhs.m22 * rhs.m23 + lhs.m23 * rhs.m33,
                lhs.m30 * rhs.m03 + lhs.m31 * rhs.m13 + lhs.m32 * rhs.m23 + lhs.m33 * rhs.m33);
    }

    pragma(inline)
    mat4 opBinary(string op)(mat4 rhs)
    {
        static if (op == "*")
            return mat4(m00 * rhs.m00 + m01 * rhs.m10 + m02 * rhs.m20 + m03 * rhs.m30,
                    m10 * rhs.m00 + m11 * rhs.m10 + m12 * rhs.m20 + m13 * rhs.m30,
                    m20 * rhs.m00 + m21 * rhs.m10 + m22 * rhs.m20 + m23 * rhs.m30,
                    m30 * rhs.m00 + m31 * rhs.m10 + m32 * rhs.m20 + m33 * rhs.m30,

                    m00 * rhs.m01 + m01 * rhs.m11 + m02 * rhs.m21 + m03 * rhs.m31,
                    m10 * rhs.m01 + m11 * rhs.m11 + m12 * rhs.m21 + m13 * rhs.m31,
                    m20 * rhs.m01 + m21 * rhs.m11 + m22 * rhs.m21 + m23 * rhs.m31,
                    m30 * rhs.m01 + m31 * rhs.m11 + m32 * rhs.m21 + m33 * rhs.m31,

                    m00 * rhs.m02 + m01 * rhs.m12 + m02 * rhs.m22 + m03 * rhs.m32,
                    m10 * rhs.m02 + m11 * rhs.m12 + m12 * rhs.m22 + m13 * rhs.m32,
                    m20 * rhs.m02 + m21 * rhs.m12 + m22 * rhs.m22 + m23 * rhs.m32,
                    m30 * rhs.m02 + m31 * rhs.m12 + m32 * rhs.m22 + m33 * rhs.m32,

                    m00 * rhs.m03 + m01 * rhs.m13 + m02 * rhs.m23 + m03 * rhs.m33,
                    m10 * rhs.m03 + m11 * rhs.m13 + m12 * rhs.m23 + m13 * rhs.m33,
                    m20 * rhs.m03 + m21 * rhs.m13 + m22 * rhs.m23 + m23 * rhs.m33,
                    m30 * rhs.m03 + m31 * rhs.m13 + m32 * rhs.m23 + m33 * rhs.m33);
        else
            static assert(0, "Operator " ~ op ~ " not implemented");
    }

    pragma(inline)
    static mat4 multiply(ref mat4 lhs, ref mat4 rhs)
    {
        return mat4(lhs.m00 * rhs.m00 + lhs.m01 * rhs.m10 + lhs.m02 * rhs.m20 + lhs.m03 * rhs.m30,
                lhs.m10 * rhs.m00 + lhs.m11 * rhs.m10 + lhs.m12 * rhs.m20 + lhs.m13 * rhs.m30,
                lhs.m20 * rhs.m00 + lhs.m21 * rhs.m10 + lhs.m22 * rhs.m20 + lhs.m23 * rhs.m30,
                lhs.m30 * rhs.m00 + lhs.m31 * rhs.m10 + lhs.m32 * rhs.m20 + lhs.m33 * rhs.m30,

                lhs.m00 * rhs.m01 + lhs.m01 * rhs.m11 + lhs.m02 * rhs.m21 + lhs.m03 * rhs.m31,
                lhs.m10 * rhs.m01 + lhs.m11 * rhs.m11 + lhs.m12 * rhs.m21 + lhs.m13 * rhs.m31,
                lhs.m20 * rhs.m01 + lhs.m21 * rhs.m11 + lhs.m22 * rhs.m21 + lhs.m23 * rhs.m31,
                lhs.m30 * rhs.m01 + lhs.m31 * rhs.m11 + lhs.m32 * rhs.m21 + lhs.m33 * rhs.m31,

                lhs.m00 * rhs.m02 + lhs.m01 * rhs.m12 + lhs.m02 * rhs.m22 + lhs.m03 * rhs.m32,
                lhs.m10 * rhs.m02 + lhs.m11 * rhs.m12 + lhs.m12 * rhs.m22 + lhs.m13 * rhs.m32,
                lhs.m20 * rhs.m02 + lhs.m21 * rhs.m12 + lhs.m22 * rhs.m22 + lhs.m23 * rhs.m32,
                lhs.m30 * rhs.m02 + lhs.m31 * rhs.m12 + lhs.m32 * rhs.m22 + lhs.m33 * rhs.m32,

                lhs.m00 * rhs.m03 + lhs.m01 * rhs.m13 + lhs.m02 * rhs.m23 + lhs.m03 * rhs.m33,
                lhs.m10 * rhs.m03 + lhs.m11 * rhs.m13 + lhs.m12 * rhs.m23 + lhs.m13 * rhs.m33,
                lhs.m20 * rhs.m03 + lhs.m21 * rhs.m13 + lhs.m22 * rhs.m23 + lhs.m23 * rhs.m33,
                lhs.m30 * rhs.m03 + lhs.m31 * rhs.m13 + lhs.m32 * rhs.m23 + lhs.m33 * rhs.m33);
    }
}

struct quat
{
    float x = 0f;
    float y = 0f;
    float z = 0f;
    float w = 0f;

    this(float x, float y, float z, float w)
    {
        this.x = x;
        this.y = y;
        this.z = z;
        this.w = w;
    }

    pragma(inline)
    float len2()
    {
        return x * x + y * y + z * z + w * w;
    }

    pragma(inline)
    quat nor()
    {
        float invMagnitude = 1f / cast(float) sqrt(x * x + y * y + z * z + w * w);
        x *= invMagnitude;
        y *= invMagnitude;
        z *= invMagnitude;
        w *= invMagnitude;
        return this;
    }
    
    quat opBinary(string op)(quat inp) const  if((op == "+") || (op == "-")) {
        quat ret;
        mixin("ret.x = x" ~ op ~ "inp.x;");
        mixin("ret.y = y" ~ op ~ "inp.y;");
        mixin("ret.z = z" ~ op ~ "inp.z;");
        mixin("ret.w = w" ~ op ~ "inp.w;");
        return ret;
    }

    quat opBinary(string op)(float inp) const if((op == "*")) {
        quat ret;
        ret.x = x * inp;
        ret.y = y * inp;
        ret.z = z * inp;
        ret.w = w * inp;
        return ret;
    }

    pragma(inline)
    static quat nlerp(quat a, quat b, float t) {
        // TODO: tests
        float dot = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z;
        quat result;
        if(dot < 0) { // Determine the "shortest route"...
            result = a - (b + a) * t; // use -b instead of b
        } else {
            result = a + (b - a) * t;
        }
        return result.nor();
    }

    pragma(inline)
    static quat identity()
    {
        return quat(0, 0, 0, 1);
    }

    pragma(inline)
    static quat from_axis(float x, float y, float z, float rad)
    {
        float d = vec3.len(x, y, z);
        if (d == 0f)
            return quat.identity;
        d = 1f / d;
        float l_ang = rad < 0 ? PI2 - (-rad % PI2) : rad % PI2;
        float l_sin = sinf(l_ang / 2);
        float l_cos = cosf(l_ang / 2);

        return quat(d * x * l_sin, d * y * l_sin, d * z * l_sin, l_cos).nor();
    }

    pragma(inline)
    static quat from_axis(const ref vec3 axis, float rad)
    {
        return from_axis(axis.x, axis.y, axis.z, rad);
    }

    pragma(inline)
    static quat lerp(const ref quat lhs, const ref quat rhs, float t)
    {
        if (t > 1f)
        {
            return rhs;
        }
        else
        {
            if (t < 0f)
            {
                return lhs;
            }
        }

        quat res;
        res.x = (rhs.x - lhs.x) * t + lhs.x;
        res.y = (rhs.y - lhs.y) * t + lhs.y;
        res.z = (rhs.z - lhs.z) * t + lhs.z;
        res.w = (rhs.w - lhs.w) * t + lhs.w;
        res.nor();
        return res;
    }

    static quat mult(const ref quat lhs, const ref quat rhs)
    {
        quat q;
        q.w = lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z;
        q.x = lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y;
        q.y = lhs.w * rhs.y + lhs.y * rhs.w + lhs.z * rhs.x - lhs.x * rhs.z;
        q.z = lhs.w * rhs.z + lhs.z * rhs.w + lhs.x * rhs.y - lhs.y * rhs.x;
        return q;
    }
}

float dot(const ref quat a, const ref quat b) {
  return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
}

quat slerp(quat a, quat b, float u) {
  // https://en.wikipedia.org/wiki/Slerp
  auto an = a.nor();
  auto bn = b.nor();
  auto d = dot(an, bn);
  if (d < 0) {
    bn = bn * -1;
    d  = -d;
  }
  if (d > 0.9995)
  {
    auto sub = bn - an;
    return (an + (sub * u)).nor();
  }
  auto th = acosf(clampf(d, cast(float)-1, cast(float)1));
  if (th == 0) return an;
  return an * (sinf(th * (1 - u)) / sinf(th)) + bn * (sinf(th * u) / sinf(th));
}

/* TODO
vec3 quat_rotate_ryg(vec3 v, quat q) {
    vec3 t = 2.0f * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}

vec3 quat_rotate_el(vec3 v, quat q) {
    vec3 b = q.xyz;
    float b2 = (b.x * b.x) + (b.y * b.y) + (b.z * b.z);
    return v * ((q.w * q.w) - b2) + b * (dot(v, b) * 2.0f) + cross(b, v) * (q.w * 2.0f);
}

vec3 quat_rotate_zeux(vec3 v, quat q) {
    return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}

*/
struct BoundingBox
{
    vec3 min;
    vec3 max;
    vec3 cnt;
    vec3 dim;

    void update()
    {
        cnt = (min + max) * 0.5;
        dim = max - min;
    }

    ref BoundingBox inf() return
    {
        min = vec3(float.infinity, float.infinity, float.infinity);
        min = vec3(-float.infinity, -float.infinity, -float.infinity);
        cnt = vec3.ZERO;
        dim = vec3.ZERO;
        return this;
    }

    void set (vec3 minimum, vec3 maximum)
    {
        min.x = minimum.x < maximum.x ? minimum.x : maximum.x;
        min.y = minimum.y < maximum.y ? minimum.y : maximum.y;
		min.z = minimum.z < maximum.z ? minimum.z : maximum.z;

        max.x = minimum.x > maximum.x ? minimum.x : maximum.x;
        max.y = minimum.y > maximum.y ? minimum.y : maximum.y;
		max.z = minimum.z > maximum.z ? minimum.z : maximum.z;
		update();
    }

    void ext(float x, float y, float z)
    {
        float minf(float a, float b)
        {
            return a > b ? b : a;
        }

        float maxf(float a, float b)
        {
            return a > b ? a : b;
        }

        vec3 minimum;
        minimum.x = minf(min.x, x);
        minimum.y = minf(min.y, y);
        minimum.z = minf(min.z, z);

        vec3 maximum;
        maximum.x = maxf(max.x, x);
        maximum.y = maxf(max.y, y);
        maximum.z = maxf(max.z, z);

        set(minimum, maximum);
    }

    bool is_valid () 
    {
		return min.x <= max.x && min.y <= max.y && min.z <= max.z;
	}
    bool intersects (ref BoundingBox b) {
		if (!is_valid()) return false;

		// test using SAT (separating axis theorem)

		float lx = abs(this.cnt.x - b.cnt.x);
		float sumx = (this.dim.x / 2.0f) + (b.dim.x / 2.0f);

		float ly = abs(this.cnt.y - b.cnt.y);
		float sumy = (this.dim.y / 2.0f) + (b.dim.y / 2.0f);

		float lz = abs(this.cnt.z - b.cnt.z);
		float sumz = (this.dim.z / 2.0f) + (b.dim.z / 2.0f);

		return (lx <= sumx && ly <= sumy && lz <= sumz);

	}
}

struct Colorf
{
    union Stuff
    {
        uint packed;
        float floatBits;
    }

    enum Colorf WHITE = hex!0xFFFFFFFF;
    enum Colorf BLACK = hex!0x000000FF;
    enum Colorf RED   = hex!0xFF0000FF;
    enum Colorf GREEN = hex!0x00FF00FF;
    enum Colorf BLUE  = hex!0x0000FFFF;

    float r;
    float g;
    float b;
    float a;

    template hex(uint value)
    {
        enum Colorf hex = {
            r: ((value & 0xff000000) >> 24) / 255f,
            g: ((value & 0x00ff0000) >> 16) / 255f,
            b: ((value & 0x0000ff00) >> 8)  / 255f,
            a: ((value & 0x000000ff))       / 255f,
        };
    }
}

struct Rectf
{
    float x = 0;
    float y = 0;
    float width = 0;
    float height = 0;
}

struct Color
{
    static union Stuff
    {
        uint packed;
        float floatBits;
    }


    enum Color WHITE = hex!0xFFFFFFFF;
    enum Color BLACK = hex!0x000000FF;


    enum Color BLUE = Color(0, 0, 255, 255);
    enum Color NAVY = Color(0, 0, 128, 255);
    enum Color ROYAL = hex!(0x4169e1ff);
    enum Color SLATE = hex!(0x708090ff);
    enum Color SKY = hex!(0x87ceebff);
    enum Color CYAN = Color(0, 255, 255, 255);
    enum Color TEAL = Color(0, 128, 128, 255);

    enum Color GREEN = hex!(0x00ff00ff);
    enum Color CHARTREUSE = hex!(0x7fff00ff);
    enum Color LIME = hex!(0x32cd32ff);
    enum Color FOREST = hex!(0x228b22ff);
    enum Color OLIVE = hex!(0x6b8e23ff);

    enum Color YELLOW = hex!(0xffff00ff);
    enum Color GOLD = hex!(0xffd700ff);
    enum Color GOLDENROD = hex!(0xdaa520ff);
    enum Color ORANGE = hex!(0xffa500ff);

    enum Color BROWN = hex!(0x8b4513ff);
    enum Color TAN = hex!(0xd2b48cff);
    enum Color FIREBRICK = hex!(0xb22222ff);

    enum Color RED = hex!(0xff0000ff);
    enum Color SCARLET = hex!(0xff341cff);
    enum Color CORAL = hex!(0xff7f50ff);
    enum Color SALMON = hex!(0xfa8072ff);
    enum Color PINK = hex!(0xff69b4ff);
    enum Color MAGENTA = Color(255, 0, 255, 255);

    enum Color PURPLE = hex!(0xa020f0ff);
    enum Color VIOLET = hex!(0xee82eeff);
    enum Color MAROON = hex!(0xb03060ff);

    ubyte r;
    ubyte g;
    ubyte b;
    ubyte a;

    template hex(uint value)
    {
        enum Color hex = {
            r: ((value & 0xff000000) >> 24),
            g: ((value & 0x00ff0000) >> 16),
            b: ((value & 0x0000ff00) >> 8) ,
            a: ((value & 0x000000ff))      ,
        };
    }

    float to_float_bits()
    {
        auto s = Stuff();
        s.packed = cast(uint)((a << 24) | (b << 16) | (g << 8) | (r));
        return s.floatBits;
    }

    Color* with_a(ubyte a) return
    {
        this.a = a; 
        return &this;
    }
}


struct Ray
{
    vec3 origin;
    vec3 direction;

    ref Ray set(vec3 o, vec3 d) return
    {
        origin = o;
        direction = d.nor();
        return this;
    }

    ref Ray mult(mat4 m) return
    {
        vec3 tmp = origin + direction;
        tmp = tmp.mul(m);
        origin = origin.mul(m);
        direction = (tmp  - origin).nor();
        return this;
    }
}

struct Outline
{
    enum Type { CIRCLE, RECT}
    struct Circle
    {
        float radius;
    }
    struct Rectangle
    {
        float rotation;
        vec2 min;
        vec2 max;
    }

    Type type;
    vec2 position;
    union
    {
        Circle circle;
        Rectangle rectangle;
    }

    float area()
    {
        final switch (type)
        {
            case Type.CIRCLE: return PI * circle.radius * circle.radius;
            case Type.RECT: {
                vec2 c = rectangle.max - rectangle.min;
                return c.x * c.y;
            }
        }
    }

    static Outline create_circle(float radius)
    {
        Outline ret;
        ret.type = Type.CIRCLE;
        ret.circle.radius = radius;
        return ret;
    }
}

// TODO: test
bool is_point_in_triangle(vec3 point, vec3 t1, vec3 t2, vec3 t3)
{
    vec3 v0 = t1 - point;
    vec3 v1 = t2 - point;
    vec3 v2 = t3 - point;

    v1 = vec3.cross(v1, v2);
    v2 = vec3.cross(v2, v0);

    if (v1.dot(v2) < 0f) return false;
    v0 = vec3.cross(v0, t2 - point);
    return (v1.dot(v0) >= 0f);
}

bool isPointInTriangle (vec2 p, vec2 a, vec2 b, vec2 c) 
{
    float px1 = p.x - a.x;
    float py1 = p.y - a.y;
    bool side12 = (b.x - a.x) * py1 - (b.y - a.y) * px1 > 0;
    if ( ( (c.x - a.x) * py1 - (c.y - a.y) * px1 > 0) == side12) return false;
    if ( ( (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x) > 0) != side12) return false;
    return true;
}

float to_rad(float value)
{
    return value * DEG2RAD;
}

enum BYTE_ANGLE_SCALE = 2;
float to_angle(ubyte value)
{
    return value * BYTE_ANGLE_SCALE;
}

ubyte to_byte(float angle)
{
    angle = angle % 360f;
    angle += angle >= 0 ? 0 : 360f;
    return cast(ubyte)(angle == 0 ? 0 : (angle / BYTE_ANGLE_SCALE));
}

float lerpf(float a, float b, float by)
{
     return a * (1 - by) + b * by;
}

float clampf(float data, float min, float max)
{
    if (data < min)
    {
        return min;
    }

    if (data > max)
    {
        return max;
    }

    return data;
}

package enum c1 = 1.70158f;
package enum c2 = c1 * 1.525;
package enum c3 = c1+1;
package enum c4 = (2.0f * PI)/3.0f;
package enum c5 = (2 * PI) / 4.5f;
package enum n1 = 7.5625f;
package enum d1 = 2.75f;

enum Easing : float function(float x)
{
    linear              = (x) => x,
    easeSmoothstep      = (x) => x * x * (3 - 2 * x),
    easeInSine          = (x) => 1 - cosf((x*PI)/2),
    easeOutSine         = (x) => sinf((x*PI)/2),
    easeInOutSine       = (x) => -(cosf(PI*x) - 1)/2,
    easeInQuad          = (x) => x*x,
    easeOutQuad         = (x) => 1 - (1-x) * (1-x),
    easeInOutQuad       = (x) => x < 0.5f ? 2 *x*x : 1 - pow(-2 * x + 2, 2)/2,
    easeInCubic         = (x) => x*x*x,
    easeOutCubic        = (x) => 1 - pow(1-x, 3),
    easeInOutCubic      = (x) => x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3)/2,
    easeInQuart         = (x) => x*x*x*x,
    easeOutQuart        = (x) => 1 - pow(1-x, 4),
    easeInOutQuart      = (x) => x < 0.5 ? 8 * x * x * x * x : 1 - pow(-2 * x + 2, 4)/2,
    easeInQuint         = (x) => x*x*x*x*x,
    easeOutQuint        = (x) => 1 - pow(1-x, 5),
    easeInOutQuint      = (x) => x < 0.5 ? 16 * x * x * x * x * x : 1 - pow(-2 * x + 2, 5)/2,
    easeInExpo          = (x) => x == 0 ? 0 : pow(2, 10 * x- 10),
    easeOutExpo         = (x) => x == 1 ? 1 : 1 - pow(2, -10 * x),
    easeInOutExpo       = (x) => x == 0 ? 0 
                                 : x == 1 ? 1 
                                 : x < 0.5 ? pow(2, 20 * x - 10)/2 
                                 : (2 - pow(2, -20 * x + 10))/2,
    easeInCirc          = (x) => 1 - sqrt(1 - pow(x, 2)),
    easeOutCirc         = (x) => sqrt(1 - pow(x - 1, 2)),
    easeInOutCirc       = (x) => x < 0.5 ? (1 - sqrt(1 - pow(2 * x, 2)))/2
                                 : (sqrt(1 - pow(-2 * x + 2, 2)) + 1) / 2,
    easeInBack          = (x) => c3 * x * x * x - c1 * x * x,
    easeOutBack         = (x) => 1 + c3 * pow(x - 1, 3) + c1 * pow(x-1, 2),
    easeInOutBack       = (x) => x < 0.5 ? (pow(2*x, 2) * ((c2+1) * 2 * x - c2))/2
                                 : (pow(2 * x - 2, 2) * ((c2 + 1) * (x * 2 - 2) + c2) + 2)/2,
    easeInElastic       = (x) => x == 0   ? 0
                                 : x == 1 ? 1 
                                 : -pow(2, 10 * x - 10) * sinf((x * 10 - 10.75f) * c4),
    easeOutElastic      = (x) => x == 0   ? 0
                                 : x == 1 ? 1
                                 : pow(2, -10 * x) * sinf((x * 10 - 0.75f) * c4) + 1,
    easeInOutElastic    = (x) => x == 0 ? 0 : x == 1 ? 1 : x < 0.5 
                                 ? -(pow(2, 20 * x - 10) * sinf((20 * x - 11.125f) * c5))/2
                                 : (pow(2, -20 * x + 10) * sinf((20 * x - 11.125f) * c5))/2 + 1,
    easeInBounce        = (x) => 1 - easeOutBounce(1 - x),
    easeOutBounce       = (x) 
                            {
                                if(x < 1.0f / d1)
                                    return n1 * x * x;
                                else if(x < 2.0f / d1)
                                    return n1 * (x-= 1.5f / d1) * x + 0.75;
                                else if(x < 2.5f / d1)
                                    return n1 * (x-= 2.25f / d1) * x + 0.9375f;
                                else
                                    return n1 * (x-= 2.625f / d1) * x + 0.984375f;
                            },
    easeInOutBounce     = (x) => x < 0.5 ? (1 - easeOutBounce(1 - 2 * x))/2
                             : (1+ easeOutBounce(2 * x - 1))/2
}



// intersector
struct Plane
{
    enum PlaneSide
    {
        OnPlane,
        Back,
        Front
    }

    vec3 normal;
    float d;

    this(vec3 normal, float d = 0)
    {
        this.normal = normal.nor();
        this.d = d;
    }

    float distance(vec3 point)
    {
        return vec3.dot(normal, point) + d;
    }

    bool isFrontFacing(vec3 direction)
    {
        float dot = vec3.dot(normal, direction);
        return dot <= 0;
    }

    PlaneSide testPoint(vec3 point)
    {
        float dist = vec3.dot(normal, point) + d;

        if (dist == 0)
            return PlaneSide.OnPlane;
        else if (dist < 0)
            return PlaneSide.Back;
        else
            return PlaneSide.Front;
    }

    PlaneSide testPoint(float x, float y, float z)
    {
        float dist = vec3.dot(normal, vec3(x, y, z)) + d;

        if (dist == 0)
            return PlaneSide.OnPlane;
        else if (dist < 0)
            return PlaneSide.Back;
        else
            return PlaneSide.Front;
    }
        
        
    // test
    //void set (const ref vec3 point1, const ref vec3 point2, const ref vec3 point3)
    //{
    //    normal = vec3.cross(point1 - point2, point2 - point3).nor();
    //    d = -vec3.dot(point1, normal);
    //}

    // test
    void Define(vec3 v0, vec3 v1, vec3 v2)
    {
        vec3 dist1 = v1 - v0;
        vec3 dist2 = v2 - v0;

        Define(vec3.cross(dist1, dist2), v0);
    }
        
    // test
    void Define(vec3 normal, vec3 point)
    {
        this.normal = normal.nor();
        d = -vec3.dot(normal, point);
    }
}

bool intersectRayPlane(Ray ray, Plane plane, vec3* intersection_out)
{
    float denom = vec3.dot(ray.direction, plane.normal);
    if (denom != 0)
    {
        float t = -(vec3.dot(ray.origin, plane.normal) + plane.d) / denom;
        if (t < 0)
        {
            *intersection_out = vec3.ZERO;
            return false;
        }

        // intersection.set(ray.origin).add(v0.set(ray.direction).scl(t));
        auto intersection = ray.origin;
        intersection += ray.direction * t;
        *intersection_out = intersection;
        return true;
    }
    else if (plane.testPoint(ray.origin) == Plane.PlaneSide.OnPlane)
    {
        *intersection_out = ray.origin;
        return true;
    }
    else
    {
        *intersection_out = vec3.ZERO;
        return false;
    }
}



struct BresenhamData {
	int step_x;
	int step_y;
	int e;
	int delta_x;
	int delta_y;
	int orig_x;
	int orig_y;
	int dest_x;
	int dest_y;
}

/**
 *  @brief initialize a bresenham_bresenham_data_t struct.
 *
 *  	after calling this function you use opus_bresenham_step to iterate
 *  	over the individual points on the line.
 *
 *  @param x_from The starting x position.
 *  @param y_from The starting y position.
 *  @param x_to The ending x position.
 *  @param y_to The ending y position.
 *  @param data Pointer to a bresenham_bresenham_data_t struct.
 */
void bresenham_init(int x_from, int y_from, int x_to, int y_to, BresenhamData* data)
{
	data.orig_x  = x_from;
	data.orig_y  = y_from;
	data.dest_x  = x_to;
	data.dest_y  = y_to;
	data.delta_x = x_to - x_from;
	data.delta_y = y_to - y_from;
	if (data.delta_x > 0) {
		data.step_x = 1;
	} else if (data.delta_x < 0) {
		data.step_x = -1;
	} else
		data.step_x = 0;
	if (data.delta_y > 0) {
		data.step_y = 1;
	} else if (data.delta_y < 0) {
		data.step_y = -1;
	} else
		data.step_y = 0;
	if (data.step_x * data.delta_x > data.step_y * data.delta_y) {
		data.e = data.step_x * data.delta_x;
		data.delta_x *= 2;
		data.delta_y *= 2;
	} else {
		data.e = data.step_y * data.delta_y;
		data.delta_x *= 2;
		data.delta_y *= 2;
	}
}

/**
 *  @brief Get the next point on a line, returns true once the line has ended.
 *  	The starting point is excluded by this function.
 *  	After the ending point is reached, the next call will return true.
 *
 *  @param cur_x An int pointer to fill with the next x position.
 *  @param cur_y An int pointer to fill with the next y position.
 *  @param data Pointer to a initialized bresenham_bresenham_data_t struct.
 *  @return 1 after the ending point has been reached, 0 otherwise.
 */
int bresenham_step(int* cur_x, int* cur_y, BresenhamData* data)
{
    if (data.step_x * data.delta_x > data.step_y * data.delta_y) {
		if (data.orig_x == data.dest_x) return 1;
		data.orig_x += data.step_x;
		data.e -= data.step_y * data.delta_y;
		if (data.e < 0) {
			data.orig_y += data.step_y;
			data.e += data.step_x * data.delta_x;
		}
	} else {
		if (data.orig_y == data.dest_y) return 1;
		data.orig_y += data.step_y;
		data.e -= data.step_x * data.delta_x;
		if (data.e < 0) {
			data.orig_x += data.step_x;
			data.e += data.step_y * data.delta_y;
		}
	}
	*cur_x = data.orig_x;
	*cur_y = data.orig_y;
	return 0;
}
