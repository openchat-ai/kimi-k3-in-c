import pandas as pd, numpy as np, json, os
D = r"F:\kimi-k3-in-c\papers\data"
F = r"F:\kimi-k3-in-c\papers\figures"
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
plt.rcParams.update({"font.size":9,"axes.grid":True,"grid.alpha":.3,"figure.dpi":170,
                     "font.family":"DejaVu Sans","axes.spines.top":False,"axes.spines.right":False})
out={}
FULL=25.83

# ---------- 1. memory ladder ----------
ml=pd.read_csv(os.path.join(D,"memory_ladder.tsv"),sep="\t")
ml["X_byte"]=(FULL-ml.gb_read)/FULL*100
ml["HRI"]=ml.expert_hit_naive-ml.X_byte
ml["ident_err"]=ml.expert_hit_true-ml.X_byte
out["ladder"]=ml[["total_gb","cache_gb","expert_hit_naive","expert_hit_true","gb_read","X_byte","HRI","ident_err"]].round(4).to_dict("records")
out["ident_max_abs_err"]=float(ml.ident_err.abs().max())

# ---------- 2. trunk/cache split ----------
tc=pd.read_csv(os.path.join(D,"trunk_cache_split.tsv"),sep="\t")
tc["X_byte"]=(FULL-tc.gb_read)/FULL*100
tc["ident_err"]=tc.hit_pct-tc.X_byte
out["split"]=tc.round(4).to_dict("records")
out["split_ident_max_abs_err"]=float(tc.ident_err.abs().max())
t128=tc[tc.total_gb==128].sort_values("trunk_gb")
out["split128_endpoints"]={"trunk_lo":float(t128.trunk_gb.iloc[0]),"trunk_hi":float(t128.trunk_gb.iloc[-1]),
 "hit_lo":float(t128.hit_pct.iloc[0]),"hit_hi":float(t128.hit_pct.iloc[-1]),
 "gb_lo":float(t128.gb_read.iloc[0]),"gb_hi":float(t128.gb_read.iloc[-1]),
 "spt_lo":float(t128.s_per_tok.iloc[0]),"spt_hi":float(t128.s_per_tok.iloc[-1])}
e=out["split128_endpoints"]
out["split128_delta"]={"gb_pct":round((e["gb_hi"]/e["gb_lo"]-1)*100,1),
                       "spt_pct":round((e["spt_hi"]/e["spt_lo"]-1)*100,1),
                       "hit_pts":round(e["hit_hi"]-e["hit_lo"],2)}
r=np.corrcoef(t128.gb_read,t128.s_per_tok)[0,1]; out["split128_corr_gb_spt"]=round(float(r),4)
t32=tc[tc.total_gb==32]
out["split32"]={"gb_read_unique":sorted(t32.gb_read.unique().tolist()),
                "hit_unique":sorted(t32.hit_pct.unique().tolist()),
                "spt_min":float(t32.s_per_tok.min()),"spt_max":float(t32.s_per_tok.max()),
                "spt_spread_pct":round(float((t32.s_per_tok.max()/t32.s_per_tok.min()-1)*100),1)}

# ---------- 3. 30 runs ----------
bt=pd.read_csv(os.path.join(D,"byte_vs_time_30runs.tsv"),sep="\t")
s=bt.s_per_tok
out["runs30"]={"n":int(len(s)),"byte_unique":sorted(bt.gb_per_tok_constant.unique().tolist()),
 "spt_min":float(s.min()),"spt_max":float(s.max()),"mean":round(float(s.mean()),2),
 "std":round(float(s.std(ddof=1)),2),"cv_pct":round(float(s.std(ddof=1)/s.mean()*100),2),
 "spread_pct":round(float((s.max()/s.min()-1)*100),1),
 "conc_mean":round(float(bt.concurrency.mean()),2),"conc_cv_pct":round(float(bt.concurrency.std(ddof=1)/bt.concurrency.mean()*100),2),
 "corr_spt_conc":round(float(np.corrcoef(s,bt.concurrency)[0,1]),4)}
# minimum detectable effect, paired vs unpaired, alpha=.05 power=.8
from scipy import stats
cv=float(s.std(ddof=1)/s.mean())
out["runs30"]["mde_unpaired_pct"]=round(float((stats.t.ppf(.975,2*6-2)+stats.t.ppf(.8,2*6-2))*cv/np.sqrt(6)*100),1)
out["runs30"]["mde_unpaired_n10_pct"]=round(float((stats.t.ppf(.975,18)+stats.t.ppf(.8,18))*cv/np.sqrt(10)*100),1)
# band count
band=out["runs30"]["mean"]
out["runs30"]["within_10pct_of_mean"]=int(((s-band).abs()<=0.10*band).sum())
out["runs30"]["within_10pct_of_min"]=int((s<=1.10*s.min()).sum())

# ---------- 4. policy arms ----------
vp=pd.read_csv(os.path.join(D,"v62_policy_bytes.tsv"),sep="\t")
g=vp.groupby(["policy","cache_gb"]).agg(byte=("expert_gb_tok","mean"),byte_sd=("expert_gb_tok","std"),
    spt=("s_per_tok","mean"),spt_sd=("s_per_tok","std"),n=("s_per_tok","size"),thr=("tok_per_hour","mean")).reset_index()
out["policy"]=g.round(4).to_dict("records")
h=vp[vp.policy=="heat"].expert_gb_tok.unique(); l=vp[vp.policy=="lru"].expert_gb_tok.unique()
out["policy_delta"]={"heat_gb":float(h[0]),"lru_gb":float(l[0]),
 "byte_save_pct":round(float((1-h[0]/l[0])*100),3),
 "byte_cv_pct":round(float(vp.groupby("policy").expert_gb_tok.apply(lambda x:x.std(ddof=1)/x.mean()*100).max()),4)}
hs=vp[vp.policy=="heat"].s_per_tok; ls=vp[vp.policy=="lru"].s_per_tok
t,p=stats.ttest_ind(hs,ls,equal_var=False)
out["policy_delta"].update({"spt_heat":round(float(hs.mean()),2),"spt_lru":round(float(ls.mean()),2),
 "spt_delta_pct":round(float((hs.mean()/ls.mean()-1)*100),2),"welch_t":round(float(t),3),"welch_p":round(float(p),3),
 "spt_cv_pct":round(float(vp.s_per_tok.std(ddof=1)/vp.s_per_tok.mean()*100),1)})
# power to detect the 1.28% byte gain using time as proxy
d=float(abs(hs.mean()-ls.mean())/np.sqrt((hs.var(ddof=1)+ls.var(ddof=1))/2))
out["policy_delta"]["cohen_d_time"]=round(d,4)
out["policy_delta"]["n_needed_time"]=int(np.ceil(2*((stats.t.ppf(.975,1000)+stats.t.ppf(.8,1000))/max(d,1e-9))**2)) if d>0 else None

# ---------- 5. bottleneck ----------
bb=pd.read_csv(os.path.join(D,"bottleneck_bound.tsv"),sep="\t")
out["bottleneck"]=bb.to_dict("records")
# ---------- 6. Ei ----------
sc=pd.read_csv(os.path.join(D,"session_cumulative_stageA.tsv"),sep="\t")
out["Ei"]={"N1":float(sc.E_i_stageA.iloc[0]),"N8":float(sc.E_i_stageA[sc.token==8].iloc[0]),
           "N32":float(sc.E_i_stageA.iloc[-1]),"measured_rows":int((sc.newkeys_source=="measured").sum()),
           "fit_rows":int((sc.newkeys_source!="measured").sum())}
# ---------- 7. triplet / tier ----------
out["triplet"]=pd.read_csv(os.path.join(D,"hit_triplet.tsv"),sep="\t").fillna("").to_dict("records")
out["tier"]=pd.read_csv(os.path.join(D,"tier_bytes_ab.tsv"),sep="\t").to_dict("records")
out["pairs"]=pd.read_csv(os.path.join(D,"v58_device_engine_pairs.tsv"),sep="\t").to_dict("records")
out["phase"]=pd.read_csv(os.path.join(D,"phase_exposure.tsv"),sep="\t").fillna("").to_dict("records")
print(json.dumps(out,ensure_ascii=False,indent=1,default=str))

# ================= FIGURES =================
C1,C2,C3,C4="#2c6fbb","#c0392b","#1e8449","#7d7d7d"
# Fig1: inflation ladder
fig,ax=plt.subplots(figsize=(6.6,3.1))
x=np.arange(len(ml))
ax.plot(x,ml.expert_hit_naive,"-o",ms=4,color=C2,label="Reported request hit rate $H_{key}$ (counts prefetch-from-disk as hit)")
ax.plot(x,ml.X_byte,"-s",ms=4,color=C1,label="Byte hit ratio $X_{byte}$ (audited)")
ax.fill_between(x,ml.X_byte,ml.expert_hit_naive,color=C2,alpha=.13)
ax.set_xticks(x);ax.set_xticklabels(ml.total_gb)
ax.set_xlabel("Provisioned host memory (GB)");ax.set_ylabel("percent")
ax.set_ylim(-4,108);ax.legend(frameon=False,loc="center left",fontsize=8)
ax.annotate("inflation gap\nup to 100 pts",xy=(1,52),fontsize=8,color=C2,ha="center")
fig.tight_layout();fig.savefig(os.path.join(F,"fig_hri_ladder.png"));plt.close(fig)

# Fig2: identity scatter true vs X_byte
fig,ax=plt.subplots(figsize=(3.5,3.3))
a=pd.concat([ml.rename(columns={"expert_hit_true":"t"}),tc.rename(columns={"hit_pct":"t"})])
ax.scatter(a.t,a.X_byte,s=22,color=C1,edgecolor="w",lw=.5,zorder=3)
lim=[-3,50];ax.plot(lim,lim,"--",lw=1,color=C4,zorder=2)
ax.set_xlim(lim);ax.set_ylim(lim);ax.set_xlabel("engine-reported byte hit ratio (% of full load)")
ax.set_ylabel("audited $X_{byte}$ (%)")
ax.set_title("max |dev| = %.3f pt (n=%d)"%(a.t.sub(a.X_byte).abs().max(),len(a)),fontsize=8.5)
fig.tight_layout();fig.savefig(os.path.join(F,"fig_identity_scatter.png"));plt.close(fig)

# Fig3: decoupling triangle (128GB split scan)
fig,ax=plt.subplots(figsize=(6.6,3.1))
xx=t128.trunk_gb.values
ax2=ax.twinx();ax2.grid(False)
l1,=ax.plot(xx,t128.gb_read,"-o",ms=4,color=C2,label="source-tier read $B_{act}$ (GB/tok)")
l2,=ax.plot(xx,t128.hit_pct,"-^",ms=4,color=C1,label="engine-reported byte hit ratio (mirror of $B_{act}$; not a request-plane field)")
l3,=ax2.plot(xx,t128.s_per_tok,"-s",ms=4,color=C3,label="wall-clock, single sample per point (s/tok)")
ax.set_xlabel("pinned trunk allocation (GB), host A total = 128 GB, N = 8")
ax.set_ylabel("GB/tok  |  percent");ax2.set_ylabel("s/tok")
ax.legend(handles=[l1,l2,l3],frameon=False,fontsize=8,loc="center right")
fig.tight_layout();fig.savefig(os.path.join(F,"fig_decoupling_split.png"));plt.close(fig)

# Fig4: detectability 鈥?bytes flat, time scattered
fig,ax=plt.subplots(figsize=(6.6,2.9))
r30=np.arange(1,31)
ax.plot(r30,bt.gb_per_tok_constant,"-o",ms=3.5,color=C1,label="delivered bytes = 216.66 GB/session = trunk 140.16 + experts 76.51 (0% spread)")
ax.set_ylabel("GB / token-session",color=C1);ax.set_ylim(200,232)
ax.tick_params(axis="y",colors=C1)
ax2=ax.twinx();ax2.grid(False)
ax2.plot(r30,bt.s_per_tok,"-s",ms=3.5,color=C2,label="wall-clock (s/tok)")
ax2.axhline(bt.s_per_tok.mean(),ls=":",lw=1,color=C4)
ax2.fill_between(r30,bt.s_per_tok.mean()*.9,bt.s_per_tok.mean()*1.1,color=C4,alpha=.12)
ax2.set_ylabel("s/tok",color=C2);ax2.tick_params(axis="y",colors=C2)
ax.set_xlabel("run index (host B, 30 runs grouped by one byte-level accounting: 4 engine versions, burst/no-burst, heat8/heat15)")
h1,la1=ax.get_legend_handles_labels();h2,la2=ax2.get_legend_handles_labels()
ax.legend(h1+h2,la1+la2,frameon=False,fontsize=8,loc="upper left")
fig.tight_layout();fig.savefig(os.path.join(F,"fig_detectability.png"));plt.close(fig)

# Fig5: policy arms 鈥?byte effect vs time effect with error bars
fig,ax=plt.subplots(figsize=(6.2,2.9))
arms=[("LRU 8G",8,"lru"),("heat 8G",8,"heat"),("LRU 15G",15,"lru"),("heat 15G",15,"heat")]
bp=[];sp=[]
for i,(lab,cg,po) in enumerate(arms):
    sub=vp[(vp.policy==po)&(vp.cache_gb==cg)]
    bp.append((sub.expert_gb_tok.mean(),sub.expert_gb_tok.std(ddof=1)))
    sp.append((sub.s_per_tok.mean(),sub.s_per_tok.std(ddof=1)))
xs=np.arange(4)
ax.errorbar(xs-0.0,[b[0] for b in bp],yerr=[b[1] for b in bp],fmt="o",color=C1,capsize=3,label="expert bytes (GB/tok)")
ax.set_ylabel("GB/tok",color=C1);ax.tick_params(axis="y",colors=C1);ax.set_ylim(25.2,26.1)
ax2=ax.twinx();ax2.grid(False)
ax2.errorbar(xs+0.0,[b[0] for b in sp],yerr=[b[1] for b in sp],fmt="s",color=C2,capsize=3,label="wall-clock (s/tok)")
ax2.set_ylabel("s/tok",color=C2);ax2.tick_params(axis="y",colors=C2)
ax.set_xticks(xs);ax.set_xticklabels([a[0] for a in arms],fontsize=8)
h1,la1=ax.get_legend_handles_labels();h2,la2=ax2.get_legend_handles_labels()
ax.legend(h1+h2,la1+la2,frameon=False,fontsize=8,loc="upper left")
fig.tight_layout();fig.savefig(os.path.join(F,"fig_policy_effect_vs_noise.png"));plt.close(fig)

# Fig6: bottleneck ratio
fig,ax=plt.subplots(figsize=(4.4,2.8))
ax.bar(bb.tier,bb.ratio,color=[C1,C2,C3,C4])
ax.axhline(1.0,ls="--",lw=1,color=C4)
ax.set_ylabel("measured / bandwidth lower bound");ax.set_xlabel("residence configuration")
for i,v in enumerate(bb.ratio):ax.text(i,v+.06,"%.2f"%v,ha="center",fontsize=8)
ax.set_ylim(0,3.6)
fig.tight_layout();fig.savefig(os.path.join(F,"fig_bound_ratio.png"));plt.close(fig)

# Fig7: E_i curve
fig,ax=plt.subplots(figsize=(4.6,2.9))
m=sc.newkeys_source=="measured"
ax.plot(sc.token,sc.E_i_stageA,"-",color=C4,lw=1,label="$E_i(N)$ (fit tail)")
ax.plot(sc.token[m],sc.E_i_stageA[m],"o",color=C2,ms=5,label="measured tokens 1-4")
ax.axhline(1,ls=":",color=C1,lw=1);ax.text(20,1.05,"lower bound $E_i$=1",fontsize=8,color=C1)
ax.set_xlabel("session length N (tokens)");ax.set_ylabel("over-read factor $E_i$")
ax.legend(frameon=False,fontsize=8)
fig.tight_layout();fig.savefig(os.path.join(F,"fig_Ei_curve.png"));plt.close(fig)
print("FIGURES_OK", os.listdir(F))

