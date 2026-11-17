import json,sys,unicodedata,jiwer
from pathlib import Path
man={i['id']:i for i in json.load(open('/Volumes/Mango/tmp/minutia-eval-fixtures/manifest.json'))['items']}
n=lambda t:"".join(c for c in unicodedata.normalize("NFKC",t) if unicodedata.category(c)[0] not in "PSZ")
for v in sys.argv[1:]:
    r=json.load(open(f'/Volumes/Mango/tmp/minutia-eval-q4/results/ja-{v}.json'))
    row={}
    for name,sel in(("fleurs",lambda i:i.startswith("fleurs")),("real",lambda i:i.startswith("real"))):
        its=[i for i in r['items'] if sel(i['id'])]
        ref=[n(man[i['id']]['reference']) for i in its]; hyp=[n(i['text']) for i in its]
        row[name]=round(100*jiwer.cer(ref,hyp),2)
        row[name+"_xRT"]=round(sum(i['durationSeconds'] for i in its)/sum(i['wallSeconds'] for i in its),1)
    print(v,row,"load",round(r['loadSeconds'],1),"peakRSS",round(r['peakRssMB']))
