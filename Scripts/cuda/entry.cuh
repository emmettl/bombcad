extern "C" __global__ void cudaSweep(Cell* src, Cell* dst, const uchar* mask,
    float* peak, float* impulse, const StepControl* control, uint* maxSpeed,
    const SolverUniforms* uniforms, float2* speciesSrc, float2* speciesDst) {
    const SolverUniforms &u = *uniforms;
    uint i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= u.nx*u.ny*u.nz) return;
    int3 cell(i % u.nx, (i/u.nx)%u.ny, i/(u.nx*u.ny));
    sweepCell(cell, src, dst, mask, peak, impulse, *control, maxSpeed, u,
        nullptr, nullptr, speciesSrc, speciesDst, nullptr, nullptr, nullptr,
        nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
        nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
}

extern "C" __global__ void cudaPrepare(StepControl* control, uint* maxSpeed, const SolverUniforms* u) {
    if (blockIdx.x == 0 && threadIdx.x == 0) portablePrepare(*control, maxSpeed, *u);
}
extern "C" __global__ void cudaMeasure(const Cell* state, const uchar* mask, uint* maxSpeed,
                                      const SolverUniforms* uniforms) {
    const SolverUniforms &u = *uniforms;
    uint i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= u.nx*u.ny*u.nz || mask[i]) return;
    Cell c = state[i];
    float rho = max(c.rho, u.densityFloor);
    float3 v = float3(c.mx,c.my,c.mz)/rho;
    float p = max(gasPressure(rho,c.energy-0.5f*rho*dot(v,v),u.airModel,u.gamma),u.pressureFloor);
    recordWaveSpeed(maxSpeed,max(fabs(v.x),max(fabs(v.y),fabs(v.z)))+sqrt(gasGamma(rho,p,u.airModel,u.gamma)*p/rho));
    recordWaveSpeed(maxSpeed+1,fabs(p-u.ambientPressure));
}
extern "C" __global__ void cudaFirstPhase(const Cell* state, const StepControl* control,
    const float4* columns, float4* records, float* open, const SolverUniforms* u) {
    uint i = blockIdx.x*blockDim.x+threadIdx.x;
    if(i >= u->nx*u->ny) return;
    uint4 parameters(u->nx,u->ny,control->stepIndex==0 && control->dt==0 ? 1u : 0u,0);
    portableFirstPhase(state,*control,columns,records,open,*u,parameters,uint2(i%u->nx,i/u->nx));
}
extern "C" __global__ void cudaCoolingClock(const StepControl* c,float* elapsed) {
    if(blockIdx.x==0 && threadIdx.x==0) *elapsed+=max(c->dt,0.0f);
}
extern "C" __global__ void cudaCoolingReset(const StepControl* c,float* elapsed) {
    if(blockIdx.x==0 && threadIdx.x==0 && c->dt>0) *elapsed=0;
}
extern "C" __global__ void cudaCoolingMedium(const Cell* state,const uchar* mask,const float2* species,
    const SolverUniforms* u,const RadiationUniforms* r,float2* medium) {
    uint i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<u->nx*u->ny*u->nz) medium[i]=radiationMediumOf(i,state,mask,species,*u,*r);
}
extern "C" __global__ void cudaCoolingLines(const float2* medium,const uchar* mask,float* loss,
    const uint* box,const SolverUniforms* u,const int4* direction) {
    uint i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<u->nx*u->ny*u->nz)
        portableRadiationLines(medium,mask,loss,box,*u,*direction,uint3(i%u->nx,(i/u->nx)%u->ny,i/(u->nx*u->ny)));
}
extern "C" __global__ void cudaCoolingApply(Cell* state,const float2* medium,const float* loss,
    const uint* box,const float* elapsed,const SolverUniforms* u,const RadiationUniforms* r,const StepControl* c) {
    uint i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i<u->nx*u->ny*u->nz && c->dt>0)
        portableRadiationApply(state,medium,loss,box,*elapsed,*u,*r,nullptr,uint3(i%u->nx,(i/u->nx)%u->ny,i/(u->nx*u->ny)));
}
