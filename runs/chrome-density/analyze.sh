#!/usr/bin/env bash
# analyze.sh <results.tsv> — median across reps per (arm, sessions), then
# per-session marginal + density (sessions / 100 GB), and a baseline-vs-trio
# comparison anchored to the report's 321 sessions/100 GB.
set -euo pipefail
TSV="${1:?usage: analyze.sh <results.tsv>}"

awk -F'\t' '
NR==1{next}
{
  key=$2 SUBSEP $3            # arm, sessions
  bind[key]=bind[key] $5 " " # collect binding samples
  anon[key]=anon[key] $6 " "
  arms[$2]=1; sess[$3]=1
  if($3+0>maxs) maxs=$3+0
}
function median(list,   a,n,i){
  n=split(list,a," ")
  if(n==0) return 0
  for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}
  if(n%2) return a[(n+1)/2]
  return (a[n/2]+a[n/2+1])/2
}
END{
  # Fixed arm order: baseline first, then trio, then any others.
  order[1]="baseline"; order[2]="trio"; no=2
  for(a in arms){ if(a!="baseline"&&a!="trio"){no++; order[no]=a} }

  printf "\n=== median fleet binding (MiB) by sessions ===\n"
  printf "%-9s","sessions"
  for(oi=1;oi<=no;oi++){ a=order[oi]; if(a in arms) printf "%14s",a }
  printf "\n"
  # collect sorted session counts
  ns=0; for(s in sess){ns++; sk[ns]=s+0}
  for(i=1;i<=ns;i++)for(j=i+1;j<=ns;j++)if(sk[j]<sk[i]){t=sk[i];sk[i]=sk[j];sk[j]=t}
  for(i=1;i<=ns;i++){
    s=sk[i]; printf "%-9d",s
    for(oi=1;oi<=no;oi++){ a=order[oi]; if(!(a in arms))continue
      m=median(bind[a SUBSEP s]); printf "%14.1f",m }
    printf "\n"
  }

  printf "\n=== median fleet anon (MiB) by sessions ===\n"
  printf "%-9s","sessions"
  for(oi=1;oi<=no;oi++){ a=order[oi]; if(a in arms) printf "%14s",a }
  printf "\n"
  for(i=1;i<=ns;i++){
    s=sk[i]; printf "%-9d",s
    for(oi=1;oi<=no;oi++){ a=order[oi]; if(!(a in arms))continue
      m=median(anon[a SUBSEP s]); printf "%14.1f",m }
    printf "\n"
  }

  # HEADLINE = anon (private, per-session, no shared-cache confound; matches the
  # report anchor 319/321). binding/sess is cache-inflated at low N, so for binding
  # we report the SLOPE (fleet[max]-fleet[1])/(max-1) = marginal cost per added
  # session, which excludes the one-time shared /nix/store page cache.
  printf "\n=== per-session marginal + density (100 GB = 102400 MiB) ===\n"
  printf "%-10s %16s %16s %16s %16s\n","arm","anon/sess MiB*","sess/100GB(anon)*","bind slope MiB","sess/100GB(slope)"
  for(oi=1;oi<=no;oi++){ a=order[oi]; if(!(a in arms))continue
    fa=median(anon[a SUBSEP maxs]); pa=(maxs>0)?fa/maxs:0
    fbmax=median(bind[a SUBSEP maxs]); fb1=median(bind[a SUBSEP 1])
    slope=(maxs>1)?(fbmax-fb1)/(maxs-1):fbmax
    da=(pa>0)?102400/pa:0; ds=(slope>0)?102400/slope:0
    printf "%-11s %15.1f %16.0f %16.1f %16.0f\n",a,pa,da,slope,ds
    dens_anon[a]=da; dens_slope[a]=ds
    if(a=="baseline"){ ba=da; bs=ds }
  }
  printf "* headline (anon = packing floor). Anchor (report): 319 MiB/sess, 321 sess/100GB.\n"
  if(ba>0) printf "\nbaseline anon vs report anchor: %.0f vs 321 sess/100GB (%+.0f%%)\n", ba, (ba-321)/321*100
  printf "\n=== each arm vs baseline (density gain) ===\n"
  printf "%-11s %18s %18s\n","arm","anon %+ vs base","slope %+ vs base"
  for(oi=1;oi<=no;oi++){ a=order[oi]; if(!(a in arms)||a=="baseline")continue
    ga=(ba>0)?(dens_anon[a]-ba)/ba*100:0
    gs=(bs>0)?(dens_slope[a]-bs)/bs*100:0
    printf "%-11s %17.0f%% %17.0f%%\n",a,ga,gs
  }
}
' "${TSV}"
