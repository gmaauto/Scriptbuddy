#!/usr/bin/env python3
"""Reproduces the ball-colour false-positive table in SPEC.md Phase 4.5. Run: python3 tools/ball_color_analysis.py"""
import random, colorsys
random.seed(7)
def inrange(h,s,v,m):
    hmin,hmax,smin,vmin,smax,vmax=m
    if not (smin<=s<=smax and vmin<=v<=vmax): return False
    return hmin<=h<=hmax if hmin<=hmax else (h>=hmin or h<=hmax)
masks={ # hue range deg, sat min, val min, sat max, val max
 'Neon pink/magenta (preset)':(315,350,.40,.45,1,1),
 'Neon orange (preset)':(10,40,.55,.45,1,1),
 'Optic yellow (hypothetical)':(50,75,.55,.55,1,1),
 'Lime/green (hypothetical)':(75,110,.55,.55,1,1),
 'White (colour mask only)':(0,360,0,.62,.22,1),
}
pops={
 'Green grass (sun+shade)':((70,150),(.25,.85),(.10,.85)),
 'Dry / dormant grass':((40,70),(.25,.60),(.30,.75)),
 'Autumn leaves, soil':((10,40),(.35,.85),(.15,.70)),
 'Bunker sand':((30,50),(.15,.40),(.55,.95)),
 'White: sky, frost, daisies, lines':((0,360),(0,.20),(.70,1.0)),
}
N=40000
print('False-positive rate of each ball-colour mask per course background (lower is better)\n')
hdr='%-28s'%''+''.join('%-14s'%k.split(' ')[0] for k in pops)+'worst'
print(hdr)
res={}
for mn,m in masks.items():
    row=[]
    for pn,(hr,sr,vr) in pops.items():
        c=0
        for _ in range(N):
            h=random.uniform(*hr)%360; s=random.uniform(*sr); v=random.uniform(*vr)
            c+=inrange(h,s,v,m)
        row.append(c/N*100)
    res[mn]=row
    print('%-28s'%mn[:28]+''.join('%-14s'%('%.1f%%'%x) for x in row)+'%.1f%%'%max(row))
# ball detectability: ball itself in sun vs shade (v .45-1, s .6-1 jitter) for chromatic; luminance contrast vs mid grass
print()
def lum(r,g,b):
    f=lambda c: c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
    return .2126*f(r)+.7152*f(g)+.0722*f(b)
grass=colorsys.hsv_to_rgb(113/360,.64,.55)
for name,hsv in [('Neon pink',(330,.75,1)),('Neon orange',(25,.9,1)),('Optic yellow',(62,.85,1)),('White',(0,0,.97))]:
    rgb=colorsys.hsv_to_rgb(hsv[0]/360,hsv[1],hsv[2])
    a,b=lum(*rgb),lum(*grass); cr=(max(a,b)+.05)/(min(a,b)+.05)
    hd=min(abs(hsv[0]-113),360-abs(hsv[0]-113)) if hsv[1]>0 else 0
    print('%-13s hue distance from grass %3d°   luminance contrast vs grass %.1f:1'%(name,hd,cr))
