#include <metal_stdlib>
using namespace metal;
struct LiquidUniforms {
 float4 viewport,geometry,optical,appearance,tint,innerShadow,misc;
};
struct LiquidVertex { float4 position [[position]]; float2 uv; };
vertex LiquidVertex lgGlassVertex(uint index [[vertex_id]]) {
 float2 p=float2((index<<1)&2,index&2);
 LiquidVertex out; out.position=float4(p*float2(2,-2)+float2(-1,1),0,1);out.uv=p;return out;
}
float liquidSDF(float2 p,float2 halfSize,float radius) {
 float2 q=abs(p)-halfSize+radius;
 return min(max(q.x,q.y),0.0)+length(max(q,0.0))-radius;
}
float liquidHeight(float t,float mode) {
 t=clamp(t,0.0,1.0);float s=1.0-t;
 if(mode<0.5)return pow(max(0.0,1.0-s*s*s*s),0.25);
 float q=1.0-min(t*2.0,1.0),convex=pow(max(0.0,1.0-q*q*q*q),0.25);
 float concave=1.0-sqrt(max(0.0,1.0-s*s))+0.1;
 float blend=t*t*t*(t*(t*6.0-15.0)+10.0);
 return mix(convex,concave,blend);
}
float3 liquidSample(texture2d<float> tex,float2 uv,float radius,float2 sourceSize) {
 constexpr sampler linearSample(coord::normalized,address::clamp_to_edge,filter::linear);
 if(radius<0.01)return tex.sample(linearSample,uv).rgb;
 const float2 offsets[16]={float2(-.94201,-.39906),float2(.94558,-.76890),float2(-.09418,-.92938),float2(.34495,.29387),float2(-.91588,-.45771),float2(-.81544,.48568),float2(-.38277,-.56071),float2(-.12675,.84686),float2(.89642,.41254),float2(.18150,-.30020),float2(-.01445,-.16001),float2(.59614,.71118),float2(.49742,-.4728),float2(.80685,.04588),float2(-.3249,-.03965),float2(-.60975,.06566)};
 float3 sum=0;for(uint i=0;i<16;i++)sum+=tex.sample(linearSample,uv+offsets[i]*radius/sourceSize).rgb;
 return sum/16.0;
}
fragment float4 lgGlassFragment(LiquidVertex in [[stage_in]],constant LiquidUniforms &u [[buffer(0)]],texture2d<float> bg [[texture(0)]]) {
 float2 size=max(u.geometry.xy,float2(1)),p=in.uv*size-size*.5;
 float radius=clamp(u.geometry.z,0.0,min(size.x,size.y)*.5);
 float sd=liquidSDF(p,size*.5,radius);
 if(sd>=0)return float4(0);
 float distance=-sd;
 float bezel=max(.5,min(u.geometry.w,max(.5,min(radius-1.0,min(size.x,size.y)*.5-1.0))));
 float t=clamp(distance/bezel,0.0,1.0),height=liquidHeight(t,u.misc.y);
 float delta=.0001,derivative=t>=1.0?0.0:(liquidHeight(min(1.0,t+delta),u.misc.y)-height)/delta;
 float2 normal=normalize(float2(-derivative,-1));
 float eta=1.0/max(1.0,u.optical.y),dotN=normal.y;
 float k=max(0.0,1.0-eta*eta*(1.0-dotN*dotN));
 float c=eta*dotN+sqrt(k);
 float2 refracted=float2(-c*normal.x,eta-c*normal.y);
 float disp=refracted.x*(height*bezel+u.optical.x)/max(.0001,refracted.y);
 float eps=.25;
 float2 grad=float2(liquidSDF(p+float2(eps,0),size*.5,radius)-liquidSDF(p-float2(eps,0),size*.5,radius),liquidSDF(p+float2(0,eps),size*.5,radius)-liquidSDF(p-float2(0,eps),size*.5,radius));
 float len=length(grad);grad=len>.00001?grad/len:float2(0);
  
 float2 offset=-grad*disp*u.optical.z*(127.0/255.0);
 float2 sourceSize=max(u.viewport.xy,float2(1));
 float2 uv=(u.viewport.zw+in.uv*size+offset)/sourceSize;
 float3 color=liquidSample(bg,uv,max(0.0,u.optical.w),sourceSize);
 float rimEdge=sqrt(max(0.0,1.0-(1.0-distance)*(1.0-distance)));
 float rimDot=abs(dot(float2(grad.x,-grad.y),float2(.5,.8660254)));
 float spec=clamp(rimDot*rimEdge,0.0,1.0);spec*=spec;
 float luminance=dot(color,float3(.2126,.7152,.0722));
 float3 saturated=clamp(mix(float3(luminance),color,u.appearance.y),0.0,1.0);
 color=mix(color,saturated,spec);
 color=mix(color,float3(1),clamp(spec*u.appearance.x,0.0,1.0));
 float shadowBlur=max(0.0,u.appearance.w),spread=u.innerShadow.w;
 float inner=0;
 if(shadowBlur>.01){float d=max(0.0,distance-spread),sigma=max(.1,shadowBlur*.5);inner=.5*exp(-.5*(d/sigma)*(d/sigma));}
 else if(spread>0)inner=1.0-smoothstep(spread-.5,spread+.5,distance);
 color=mix(color,u.innerShadow.xyz,clamp(inner,0.0,1.0));
 color=mix(color,u.tint.xyz,clamp(u.appearance.z,0.0,.4));
 float alpha=smoothstep(0.0,.8,distance);
 return float4(clamp(color,0.0,1.0)*alpha,alpha);
}
