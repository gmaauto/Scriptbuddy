#!/usr/bin/env python3
"""Reference planar model used to fit AerodynamicModel coefficients against PGA Tour TrackMan averages.
Run: python3 tools/fit_aero_coefficients.py"""
import math,itertools
m=0.04593; r=0.021335; A=math.pi*r*r; rho=1.225; g=9.80665
def run(v0,th,rpm,cd0,cds,cl0,cls,clmax,tau=25.0,dt=0.01):
    th=math.radians(th); s=[0,0,v0*math.cos(th),v0*math.sin(th)]; t=0; w0=rpm*2*math.pi/60
    def f(t,s):
        x,z,vx,vz=s; v=math.hypot(vx,vz); w=w0*math.exp(-t/tau); S=r*w/v; k=0.5*rho*A*v/m
        cd=cd0+cds*S; cl=min(clmax,cl0+cls*S)
        return [vx,vz,-k*(cd*vx + cl*vz), -g + k*(cl*vx - cd*vz)]
    while True:
        k1=f(t,s); k2=f(t+dt/2,[a+dt/2*b for a,b in zip(s,k1)]); k3=f(t+dt/2,[a+dt/2*b for a,b in zip(s,k2)]); k4=f(t+dt,[a+dt*b for a,b in zip(s,k3)])
        n=[a+dt/6*(b+2*c+2*d+e) for a,b,c,d,e in zip(s,k1,k2,k3,k4)]
        if n[1]<0 and t>0:
            fr=s[1]/(s[1]-n[1]); return (s[0]+fr*(n[0]-s[0]))/0.9144
        s=n; t+=dt
cases=[(167,10.9,2686,275),(120,16.3,7097,172),(102,24.2,9304,136),(132,12.6,4350,192)]  # PGA tour avg drv,7i,PW,3w-ish? (3w: 158mph,9.3,3655,243)
cases[3]=(158,9.3,3655,243)  # 3-wood
best=None
for p in itertools.product([0.16,0.17,0.18],[0.3,0.45,0.6],[0.05,0.08,0.11],[0.6,0.9,1.2],[0.25,0.3,0.35]):
    e=sum((run(v*0.44704,th,rp,*p,dt=0.02)-c)**2 for v,th,rp,c in cases)
    if best is None or e<best[0]: best=(e,p)
print(best,[round(run(v*0.44704,th,rp,*best[1]),1) for v,th,rp,c in cases])
