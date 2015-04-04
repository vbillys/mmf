#include <iostream>
#include <cuda.h>
#include <curand.h>
#include <curand_kernel.h>
#include <stdio.h>
#include "SimpleProfiler.h"
#include <math.h>
#include <iostream>
#include <limits.h>
#include "gpu_random.h"
#include "fixed_matrix.h"
#include "fixed_vector.h"
#include "SimpleImage.h"
#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }

inline void gpuAssert(cudaError_t code, char *file, int line, bool abort=true)
{
    if (code != cudaSuccess)
    {
        fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
        if (abort) exit(code);
    }
}

const uint MAX_IMAGE_CHANNELS=7;
template<class T, unsigned int N> __device__ void draw_image_given_r(RandStruct &str,T r, FixedVector<T,N> & img, T sigma)
{
    img[0]=randn_wanghash(str)*sigma+r;
}
__device__  float draw_surface_value(RandStruct &str, float r0)
{
    return randn_wanghash(str)+r0;
}

/*
  u:   normals
  rhs: 
  u0:  
 */
__global__ void RBGS_update(SimpleImage u, SimpleImage rhs,SimpleImage u0, float hx, float hy, float fidelity, float r,uint turn)
{
    uint id_x = blockIdx.x*blockDim.x+threadIdx.x;
    uint id_y = blockIdx.y*blockDim.y+threadIdx.y;
    if (id_x>=u.width || id_y>=u.height)
    {
        return;
    }
    float divsqy=1.f/hy/hy;
    float divsqx=1.f/hx/hx;
//    u.getPixel3D(id_x,id_y,0)=id_x;
//    u.getPixel3D(id_x,id_y,1)=1;
    for (uint id_z=0; id_z<u.depth; ++id_z)
    {
        uint tidx=id_x+id_y+id_z;
        if ((tidx-turn)%2==0)
        {
            float w=fidelity;
            float sum=0.f;
            if (r>0.f &&rhs.data)
            {
                sum=sum+r*rhs.getPixel3D(id_x,id_y,id_z);
            }
            if (fidelity>0 && u0.data)
            {
                sum=sum+fidelity*u0.getPixel3D(id_x,id_y,id_z);
            }
            if (id_x>0 )
            {
                w=w+r*divsqx;
                sum=sum+r*u.getPixel3D(id_x-1,id_y,id_z)*divsqx;
            }
            if (id_y>0 )
            {
                w=w+r*divsqy;
                sum=sum+r*u.getPixel3D(id_x,id_y-1,id_z)*divsqy;
            }
            if (id_x<(u.width-1) )
            {
                w=w+r*divsqx;
                sum=sum+r*u.getPixel3D(id_x+1,id_y,id_z)*divsqx;
            }
            if (id_y<(u.height-1) )
            {
                w=w+r*divsqy;
                sum=sum+r*u.getPixel3D(id_x,id_y+1,id_z)*divsqy;
            }
            u.getPixel3D(id_x,id_y,id_z)=sum/w;
        }
    }
    //}
    //src[id]=1.f;
}

template<class T> __device__ __host__ inline T sqr(const T& a)
{
    return a*a;
}
__global__ void normal_projection(SimpleImage v, SimpleImage u)
{
    uint id_x = blockIdx.x*blockDim.x+threadIdx.x;
    uint id_y = blockIdx.y*blockDim.y+threadIdx.y;
    //  dest[0]=0.f;
//    src[0]=0.f;
    //  src[0]=0.f;
    if (id_x>=u.width	|| id_y>=u.height )
    {
        return;
    }
    float sum=0;
    for(int i=0; i<v.depth; ++i)
    {
        sum=sum+sqr(v.getPixel3D(id_x,id_y,i));
    }
    for(int i=0; i<3; ++i)
    {
        u.getPixel3D(id_x,id_y,i)=v.getPixel3D(id_x,id_y,i)/sqrtf(sum+1e-15f);
    }

}

// update p according to
//
__global__ void update_rhs(SimpleImage u, SimpleImage p, SimpleImage mu,  float r)
{
    uint id_x = blockIdx.x*blockDim.x+threadIdx.x;
    uint id_y = blockIdx.y*blockDim.y+threadIdx.y;
    if (id_x>=u.width	|| id_y>=u.height )
    {
        return;
    }
    float sum=0;
    //uint id=id_x+id_y*u.pitch/sizeof(SimpleImage::T);
    for(int i=0; i<u.depth; ++i)
    {
        float gux=id_x<(u.width-1)?u.getPixel3D(id_x+1,id_y,i)-u.getPixel3D(id_x,id_y,i):0;
        float guy=id_y<(u.height-1)?u.getPixel3D(id_x,id_y+1,i)-u.getPixel3D(id_x,id_y,i):0;
        float wx=r*gux-mu.getPixel3D(id_x,id_y,2*i);
        float wy=r*guy-mu.getPixel3D(id_x,id_y,2*i+1);
        sum=sum+sqr(wx);
        sum=sum+sqr(wy);
    }
    float nw=sqrtf(sum);
    float fract=max(0.f,1-1/nw);
    for(int i=0; i<u.depth; ++i)
    {
        float gux=id_x<(u.width-1)?u.getPixel3D(id_x+1,id_y,i)-u.getPixel3D(id_x,id_y,i):0;
        float guy=id_y<(u.height-1)?u.getPixel3D(id_x,id_y+1,i)-u.getPixel3D(id_x,id_y,i):0;
        float wx=r*gux-mu.getPixel3D(id_x,id_y,2*i);
        float wy=r*guy-mu.getPixel3D(id_x,id_y,2*i+1);
        p.getPixel3D(id_x,id_y,2*i)=1.f/r*(fract)*wx;
        p.getPixel3D(id_x,id_y,2*i+1)=1.f/r*(fract)*wy;

    }

}

__global__ void update_rhs2(SimpleImage p, SimpleImage rhs, float r)
{
    uint id_x = blockIdx.x*blockDim.x+threadIdx.x;
    uint id_y = blockIdx.y*blockDim.y+threadIdx.y;
    if (id_x>=rhs.width	|| id_y>=rhs.height )
    {
        return;
    }
    for(int i=0; i<rhs.depth; ++i)
    {
        float divp=0.f;
        float px = id_x>0?p.getPixel3D(id_x,id_y,2*i)-p.getPixel3D(id_x-1,id_y,2*i):0;
        float py = id_y>0?p.getPixel3D(id_x,id_y,2*i+1)-p.getPixel3D(id_x,id_y-1,2*i+1):0;
        divp=divp+px;
        divp=divp+py;
        rhs.getPixel3D(id_x,id_y,i)=rhs.getPixel3D(id_x,id_y,i)-divp;
    }
}

__global__ void update_mu(SimpleImage mu, SimpleImage p, SimpleImage u, float r)
{
    uint id_x = blockIdx.x*blockDim.x+threadIdx.x;
    uint id_y = blockIdx.y*blockDim.y+threadIdx.y;
    if (id_x>=u.width	|| id_y>=u.height )
    {
        return;
    }
    for(int i=0; i<u.depth; ++i)
    {
        float ux = id_x>0?u.getPixel3D(id_x,id_y,i)-p.getPixel3D(id_x-1,id_y,i):0;
        float uy = id_y>0?u.getPixel3D(id_x,id_y,i)-p.getPixel3D(id_x,id_y-1,i):0;
        float dx=ux-p.getPixel3D(id_x,id_y,2*i);
        float dy=uy-p.getPixel3D(id_x,id_y,2*i+1);
        mu.getPixel3D(id_x,id_y,2*i)=mu.getPixel3D(id_x,id_y,2*i)+r*(dx);
        mu.getPixel3D(id_x,id_y,2*i+1)=mu.getPixel3D(id_x,id_y,2*i+1)+r*(dy);

    }
}

void normal_smoothing(SimpleImage& res_img, float fidelity,uint iter)
{
    uint width=res_img.width;
    uint height=res_img.height;
    uint depth=res_img.depth;
    float r=1;
    const dim3 imageSize(width,height,depth);
    const dim3 blockSize(32,16,1);
// load to GPU
    SimpleImage *o_u=new SimpleImage(width,height,depth,(float*)0);
    o_u->allocate_2D_image(width,height,res_img.data,depth);
    gpuErrchk( cudaPeekAtLastError() );
    SimpleImage *u0=new SimpleImage(width,height,depth,(float*)0);
    u0->allocate_2D_image(width,height,res_img.data,depth);
    gpuErrchk( cudaPeekAtLastError() );
    SimpleImage *p=new SimpleImage(width,height,depth*2,(float*)0);
    p->allocate_2D_image(width,height,0,depth*2);
    gpuErrchk( cudaPeekAtLastError() );
    SimpleImage *rhs=new SimpleImage(width,height,depth,(float*)0);
    rhs->allocate_2D_image(width,height,0,depth);
    gpuErrchk( cudaPeekAtLastError() );
    SimpleImage *mu=new SimpleImage(width,height,depth*2,(float*)0);
    mu->allocate_2D_image(width,height,0,depth*2);
    gpuErrchk( cudaPeekAtLastError() );
    size_t gridCols = (width + blockSize.x - 1) / blockSize.x;
    size_t gridRows = (height + blockSize.y - 1) / blockSize.y;
    size_t gridLayers = (depth + blockSize.z - 1) / blockSize.z;
    const dim3 gridSize(gridCols,gridRows,1);
    cerr<<"fidelity"<<fidelity<<"\n";
    //cerr<<"writing to: "<<o_u->data<<"\n";
    for (int it=0; it<iter; ++it)
    {
        if (it%2==0)
        {
            if (it%4==0){
             //  update_mu<<<gridSize,blockSize>>>(*mu,*p,*o_u,r);
            }
            //update_rhs<<<gridSize,blockSize>>>(*o_u,*p,*mu,r);
            //update_rhs2<<<gridSize,blockSize>>>(*p,*rhs,r);
        }
        RBGS_update<<<gridSize,blockSize>>>(*o_u,*rhs,*u0,1.f,1.f,fidelity,r,it%2);

        //normal_projection<<<gridSize,blockSize>>>(*o_u,*o_u);
    }
    cerr<<"Copying..";
    o_u->copy_to_host(res_img);
    gpuErrchk( cudaPeekAtLastError() );
    o_u->dealloc();
    gpuErrchk( cudaPeekAtLastError() );
    //  cerr<<"Clearing o_u";
    delete o_u;
    gpuErrchk( cudaPeekAtLastError() );

    p->dealloc();
    delete p;
    gpuErrchk( cudaPeekAtLastError() );
    mu->dealloc();
    delete mu;
    gpuErrchk( cudaPeekAtLastError() );
//    cerr<<"Clearing u0";
    u0->dealloc();
    delete u0;
    gpuErrchk( cudaPeekAtLastError() );

    rhs->dealloc();
    delete rhs;
}

