kernel void referenceSweep(device Cell* src [[buffer(0)]], device Cell* dst [[buffer(1)]],
    const device uchar* mask [[buffer(2)]], device float* peak [[buffer(3)]],
    device float* impulse [[buffer(4)]], const device StepControl& control [[buffer(5)]],
    device atomic_uint* maxSpeed [[buffer(6)]], constant SolverUniforms& u [[buffer(7)]],
    device float2* speciesSrc [[buffer(8)]], device float2* speciesDst [[buffer(9)]],
    uint i [[thread_position_in_grid]]) {
    if(i>=u.nx*u.ny*u.nz) return;
    int3 cell(i%u.nx,(i/u.nx)%u.ny,i/(u.nx*u.ny));
    sweepCell(cell,src,dst,mask,peak,impulse,control,maxSpeed,u,
        nullptr,nullptr,speciesSrc,speciesDst,nullptr,nullptr,nullptr,
        nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,
        nullptr,nullptr,nullptr,nullptr,nullptr,nullptr);
}
kernel void referencePrepare(device StepControl& control [[buffer(0)]],
    device atomic_uint* speed [[buffer(1)]],constant SolverUniforms& u [[buffer(2)]],
    uint i [[thread_position_in_grid]]) {
    if(i==0) portablePrepare(control,speed,u);
}
kernel void referenceMeasure(const device Cell* state [[buffer(0)]],const device uchar* mask [[buffer(1)]],
    device atomic_uint* maxSpeed [[buffer(2)]],constant SolverUniforms& u [[buffer(3)]],
    uint i [[thread_position_in_grid]]) {
    if(i>=u.nx*u.ny*u.nz || mask[i]) return;
    Cell c=state[i];float rho=max(c.rho,u.densityFloor);
    float3 v=float3(c.mx,c.my,c.mz)/rho;
    float p=max(gasPressure(rho,c.energy-0.5f*rho*dot(v,v),u.airModel,u.gamma),u.pressureFloor);
    recordWaveSpeed(maxSpeed,max(fabs(v.x),max(fabs(v.y),fabs(v.z)))+sqrt(gasGamma(rho,p,u.airModel,u.gamma)*p/rho));
    recordWaveSpeed(maxSpeed+1,fabs(p-u.ambientPressure));
}
kernel void referenceFirstPhase(const device Cell* state [[buffer(0)]],
    const device StepControl& control [[buffer(1)]],const device float4* columns [[buffer(2)]],
    device float4* records [[buffer(3)]],device float* open [[buffer(4)]],
    constant SolverUniforms& u [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    if(i>=u.nx*u.ny) return;
    uint4 parameters(u.nx,u.ny,control.stepIndex==0 && control.dt==0 ? 1u : 0u,0);
    portableFirstPhase(state,control,columns,records,open,u,parameters,uint2(i%u.nx,i/u.nx));
}
kernel void referenceCoolingClock(const device StepControl& c [[buffer(0)]],device float& elapsed [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    if(i==0) elapsed+=max(c.dt,0.0f);
}
kernel void referenceCoolingReset(const device StepControl& c [[buffer(0)]],device float& elapsed [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    if(i==0 && c.dt>0) elapsed=0;
}
kernel void referenceCoolingMedium(const device Cell* state [[buffer(0)]],const device uchar* mask [[buffer(1)]],const device float2* species [[buffer(2)]],
    constant SolverUniforms& u [[buffer(3)]],constant RadiationUniforms& r [[buffer(4)]],device float2* medium [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    if(i<u.nx*u.ny*u.nz) medium[i]=radiationMediumOf(i,state,mask,species,u,r);
}
kernel void referenceCoolingLines(const device float2* medium [[buffer(0)]],const device uchar* mask [[buffer(1)]],device float* loss [[buffer(2)]],
    const device uint* box [[buffer(3)]],constant SolverUniforms& u [[buffer(4)]],constant int4& direction [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    if(i<u.nx*u.ny*u.nz) portableRadiationLines(medium,mask,loss,box,u,direction,uint3(i%u.nx,(i/u.nx)%u.ny,i/(u.nx*u.ny)));
}
kernel void referenceCoolingApply(device Cell* state [[buffer(0)]],const device float2* medium [[buffer(1)]],const device float* loss [[buffer(2)]],
    const device uint* box [[buffer(3)]],const device float& elapsed [[buffer(4)]],constant SolverUniforms& u [[buffer(5)]],constant RadiationUniforms& r [[buffer(6)]],const device StepControl& c [[buffer(7)]],uint i [[thread_position_in_grid]]) {
    if(i<u.nx*u.ny*u.nz && c.dt>0) portableRadiationApply(state,medium,loss,box,elapsed,u,r,nullptr,uint3(i%u.nx,(i/u.nx)%u.ny,i/(u.nx*u.ny)));
}
