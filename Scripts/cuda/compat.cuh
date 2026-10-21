#define float2 bc_float2
#define float3 bc_float3
#define float4 bc_float4
#define int2 bc_int2
#define int3 bc_int3
#define int4 bc_int4
#define uint2 bc_uint2
#define uint3 bc_uint3
#define uint4 bc_uint4
// Minimal Metal value semantics for the generated CUDA air sweep.
// Vector alignment is internal: the wire types are scalar-only Cell and uniforms.
typedef unsigned int uint;
typedef unsigned char uchar;
typedef unsigned long long ulong;
typedef uint atomic_uint;
constexpr int memory_order_relaxed = 0;
#define D __device__ __forceinline__
template<class T, int N> struct V {
    T x, y, z, w;
    D V() : x(0), y(0), z(0), w(0) {}
    D V(T a) : x(a), y(a), z(a), w(a) {}
    D V(T a,T b) : x(a), y(b), z(0), w(0) {}
    D V(T a,T b,T c) : x(a), y(b), z(c), w(0) {}
    D V(T a,T b,T c,T d) : x(a), y(b), z(c), w(d) {}
    template<class U> D V(V<U,N> a) : x(T(a.x)),y(T(a.y)),z(T(a.z)),w(T(a.w)) {}
    D V(V<T,2> a,V<T,2> b):x(a.x),y(a.y),z(b.x),w(b.y){}
    D V(V<T,3> a,T b):x(a.x),y(a.y),z(a.z),w(b){}
    D V(T a,V<T,3> b):x(a),y(b.x),z(b.y),w(b.z){}
    D V(V<T,2> a,T b,T c):x(a.x),y(a.y),z(b),w(c){}
    D T& operator[](int i) { return (&x)[i]; }
    D T operator[](int i) const { return (&x)[i]; }
    D V<T,2> xy() const {return {x,y};}
    D V<T,2> zw() const {return {z,w};}
    D V<T,3> xyz() const {return {x,y,z};}
    D V<T,3> yzw() const {return {y,z,w};}
    D V<T,3> yzx() const {return {y,z,x};}
    D V<T,3> zxy() const {return {z,x,y};}
};
// Metal float2 arrays have an 8-byte stride, unlike padded float3 values.
template<class T> struct V<T,2> {
    T x,y;
    D V():x(0),y(0){}
    D V(T a):x(a),y(a){}
    D V(T a,T b):x(a),y(b){}
    template<class U> D V(V<U,2>a):x(T(a.x)),y(T(a.y)){}
    D T& operator[](int i){return (&x)[i];}
    D T operator[](int i)const{return (&x)[i];}
    D V<T,2> xy()const{return *this;}
};
static_assert(sizeof(V<float,2>) == 8, "species ABI");
using float2=V<float,2>; using float3=V<float,3>; using float4=V<float,4>;
using int2=V<int,2>; using int3=V<int,3>; using int4=V<int,4>;
using uint2=V<uint,2>; using uint3=V<uint,3>; using uint4=V<uint,4>;
#define BINARY(OP) \
template<class T,int N> D V<T,N> operator OP(V<T,N>a,V<T,N>b){V<T,N>r;for(int i=0;i<N;i++)r[i]=a[i] OP b[i];return r;} \
template<class T,int N,class U> D V<T,N> operator OP(V<T,N>a,U b){return a OP V<T,N>(T(b));} \
template<class T,int N,class U> D V<T,N> operator OP(U a,V<T,N>b){return V<T,N>(T(a)) OP b;}
BINARY(+) BINARY(-) BINARY(*) BINARY(/) BINARY(%)
#define COMP(OP) \
template<class T,int N> D V<int,N> operator OP(V<T,N>a,V<T,N>b){V<int,N>r;for(int i=0;i<N;i++)r[i]=a[i] OP b[i];return r;} \
template<class T,int N,class U> D V<int,N> operator OP(V<T,N>a,U b){return a OP V<T,N>(T(b));}
COMP(<) COMP(>) COMP(<=) COMP(>=) COMP(==) COMP(!=)
template<class T,int N> D V<T,N> operator-(V<T,N>a){for(int i=0;i<N;i++)a[i]=-a[i];return a;}
template<class T,int N> D V<T,N>& operator+=(V<T,N>&a,V<T,N>b){a=a+b;return a;}
template<class T,int N> D V<T,N>& operator-=(V<T,N>&a,V<T,N>b){a=a-b;return a;}
template<class T,int N> D V<T,N>& operator*=(V<T,N>&a,T b){a=a*b;return a;}
template<class T,int N> D V<T,N>& operator/=(V<T,N>&a,T b){a=a/b;return a;}
template<class T,int N> D bool all(V<T,N>a){for(int i=0;i<N;i++)if(!a[i])return false;return true;}
template<class T,int N> D bool any(V<T,N>a){for(int i=0;i<N;i++)if(a[i])return true;return false;}
template<class T> D T min(T a,T b){return a<b?a:b;}
template<class T> D T max(T a,T b){return a>b?a:b;}
template<class T> D T clamp(T a,T b,T c){return min(max(a,b),c);}
template<class T,int N> D V<T,N> fabs(V<T,N>a){for(int i=0;i<N;i++)a[i]=fabsf(a[i]);return a;}
template<class T,int N> D V<T,N> abs(V<T,N>a){for(int i=0;i<N;i++)a[i]=a[i]<0?-a[i]:a[i];return a;}
template<class T,int N> D V<T,N> select(V<T,N>a,V<T,N>b,V<int,N>c){for(int i=0;i<N;i++)if(c[i])a[i]=b[i];return a;}
D float dot(float3 a,float3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
D float3 cross(float3 a,float3 b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
D float powr(float a,float b){return powf(a,b);}
D uint floatBits(float a){return __float_as_uint(a);}
D uint atomic_load_explicit(uint*p,int){return atomicAdd(p,0u);}
D uint atomic_fetch_max_explicit(uint*p,uint a,int){return atomicMax(p,a);}
D void atomic_store_explicit(uint*p,uint a,int){atomicExch(p,a);}

template<class T,int N> D V<T,N> min(V<T,N>a,V<T,N>b){for(int i=0;i<N;i++)a[i]=min(a[i],b[i]);return a;}
template<class T,int N> D V<T,N> max(V<T,N>a,V<T,N>b){for(int i=0;i<N;i++)a[i]=max(a[i],b[i]);return a;}
template<class T,int N> D V<T,N> max(V<T,N>a,T b){return max(a,V<T,N>(b));}
template<class T,int N> D V<T,N> min(V<T,N>a,T b){return min(a,V<T,N>(b));}
template<int N> D V<float,N> floor(V<float,N>a){for(int i=0;i<N;i++)a[i]=floorf(a[i]);return a;}

D float bitsFloat(uint a){return __uint_as_float(a);}
D uint atomic_exchange_explicit(uint*p,uint a,int){return atomicExch(p,a);}
#ifndef NAN
#define NAN __uint_as_float(0x7fc00000u)
#endif
#ifndef M_PI_F
#define M_PI_F 3.14159265358979323846f
#endif
